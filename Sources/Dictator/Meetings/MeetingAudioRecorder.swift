import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import ScreenCaptureKit
import AppKit
import os

/// Captures **system audio** for one meeting via ScreenCaptureKit. Writes
/// a single CAF file (system.caf) into the meeting's folder.
///
/// SCK's own `.microphone` output dropped buffers silently on at least one
/// test Mac (delegate fired but the writes never landed on disk), so the
/// mic track is captured by a sibling `MeetingMicRecorder` running its own
/// AVCaptureSession — same proven path the dictation flow uses every day.
/// Two recorders run in parallel for the duration of the meeting; the
/// session orchestrates their lifecycle.
///
/// We pick the smallest possible content filter (2×2 pixels, 1 fps) and
/// drop video buffers as they arrive — SCK refuses to start without a
/// video stream, but the per-frame cost is negligible at that size.
@MainActor
final class MeetingAudioRecorder {
    /// SCStream sample rate. 48 kHz is SCK's preferred output; we downsample
    /// at ASR time, so picking the higher rate avoids upsample artifacts.
    private static let sampleRate: Double = 48_000
    private static let channelCount: Int = 2

    private var stream: SCStream?
    private var output: StreamOutputForwarder?
    private var systemFile: AVAudioFile?
    private var running = false

    /// Where the system audio is being written. Populated by `start`.
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Fired once SCStream is producing buffers. The session's
    /// `warmingUp` → `recording` pivot hangs off this.
    var onReady: (@MainActor () -> Void)?

    /// Fired on each successful system-audio buffer with the current
    /// system RMS level (0…1). The mic level is owned by
    /// `MeetingMicRecorder` and arrives on a separate callback. The mic
    /// argument here is retained as 0 to keep the API ergonomic for
    /// callers that snapshot both into the same state.
    var onLevel: (@MainActor (_ mic: Float, _ system: Float) -> Void)?

    /// Fired if SCStream stops itself outside our control (user revoked
    /// the grant mid-recording, display went to sleep on system sleep
    /// without us holding an idle assertion). Recorder is left torn down.
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    /// Fired once per recording with a human-readable reason the system
    /// capture looks unhealthy. The classic case is FaceTime, Apple
    /// Music, and a handful of other Apple apps that ScreenCaptureKit
    /// refuses to surface audio for — buffers arrive for the rest of the
    /// desktop but never carry the meeting itself. The session pipes
    /// this into its `captureWarnings` collection which surfaces in the
    /// LiveRecordingView banner.
    var onCaptureWarning: (@MainActor (String) -> Void)?

    /// Flipped on the SCStream audio queue the first time a real audio
    /// buffer arrives. Read on the main actor by the bring-up watchdog
    /// 5s after start. `OSAllocatedUnfairLock<Bool>` is the async-safe
    /// primitive: `NSLock` traps when called from an async context
    /// under Swift 6 strict concurrency.
    private let firstAudioBufferFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var bringUpWatchdog: Task<Void, Never>?

    /// Optional sink for raw system-audio sample buffers, fired alongside
    /// the on-disk write. The live-transcript service hangs off this so it
    /// can re-encode each buffer for Parakeet without us having to plumb a
    /// second SCStream output. **Fires on the SCStream audio dispatch
    /// queue (`Self.audioQueue`), not the main actor** — the callee is
    /// responsible for any actor hop. Read on the audio queue; rebound in
    /// `start` and never reassigned mid-stream.
    var onBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    private var lastSystemLevel: Float = 0

    init() {}

    /// Build the SCStream, open both AVAudioFiles lazily on first sample,
    /// and begin capture. Throws on permission denied, content-filter
    /// failure, or AVAudioFile setup. The meta.json is the session's
    /// responsibility, not ours.
    func start(folder: URL, preferredMicUID: String?) async throws {
        guard !running else { return }
        _ = preferredMicUID // mic capture lives in MeetingMicRecorder now

        let systemPath = folder.appendingPathComponent(MeetingStorage.systemFilename)
        self.systemURL = systemPath
        try? FileManager.default.removeItem(at: systemPath)

        NSLog("[Dictator] MeetingSystem: starting — destination=\(systemPath.lastPathComponent)")

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            NSLog("[Dictator] MeetingSystem: no display in SCShareableContent — aborting")
            throw NSError(
                domain: "Dictator.Meetings", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for the content filter."]
            )
        }

        // Exclude our own bundle so the recorder doesn't capture
        // Dictator's own UI sounds (or future chimes) into system.m4a.
        let ownBundleID = Bundle.main.bundleIdentifier ?? "net.robgough.Dictator"
        let runningApp = content.applications.first { $0.bundleIdentifier == ownBundleID }
        let exclude: [SCRunningApplication] = runningApp.map { [$0] } ?? []
        let filter = SCContentFilter(display: display, excludingApplications: exclude, exceptingWindows: [])
        NSLog("[Dictator] MeetingSystem: filter built — display=\(display.displayID), excludeOwnApp=\(runningApp != nil)")

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // SCK's `.microphone` output was unreliable on this codebase's test
        // hardware — buffers arrived but never landed on disk and no error
        // was raised. Mic capture moved out to a parallel AVCaptureSession
        // (see `MeetingMicRecorder`); SCStream is now system-only.
        config.captureMicrophone = false
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Self.channelCount
        // Minimum-cost video stream — SCK requires it, but we drop every
        // .screen sample on arrival.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let forwarder = StreamOutputForwarder(owner: self, bufferSink: onBuffer)
        // Attach the forwarder as both output and delegate — without the
        // delegate we miss didStopWithError, which is the only way to find
        // out SCK stopped the stream for us (permission revoked, display
        // disconnected, etc.).
        let stream = SCStream(filter: filter, configuration: config, delegate: forwarder)
        try stream.addStreamOutput(forwarder, type: .audio, sampleHandlerQueue: Self.audioQueue)
        try stream.addStreamOutput(forwarder, type: .screen, sampleHandlerQueue: Self.videoQueue)

        try await stream.startCapture()
        NSLog("[Dictator] MeetingSystem: SCStream startCapture returned, awaiting first audio buffer")

        // Reset the first-buffer flag before declaring the recorder
        // running so the watchdog has a clean signal. The audio queue
        // may already be racing to deliver buffers — the lock serialises
        // them safely.
        firstAudioBufferFlag.withLock { $0 = false }

        self.stream = stream
        self.output = forwarder
        self.running = true
        self.startedAt = Date()
        startBringUpWatchdog()
        onReady?()
    }

    /// Arm a 5-second timer that checks whether SCStream is actually
    /// delivering audio buffers. ScreenCaptureKit happily reports a
    /// running stream for some Apple apps (FaceTime, Apple Music, the
    /// short list of "protected" apps that block screen-recording-shaped
    /// capture) while silently never emitting audio for the app of
    /// interest. We can't force capture if Apple has decided not to
    /// surface it; we just need to tell the user instead of leaving
    /// them on a flat system meter for the whole call.
    private func startBringUpWatchdog() {
        bringUpWatchdog?.cancel()
        bringUpWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.running else { return }
            let saw = self.firstAudioBufferFlag.withLock { $0 }
            guard !saw else { return }
            NSLog("[Dictator] MeetingSystem: no audio buffers in 5s — likely a protected app (FaceTime / Apple Music) blocking capture")
            self.onCaptureWarning?("Dictator couldn't capture system audio. FaceTime, Apple Music, and a handful of other Apple apps block ScreenCaptureKit from recording their audio. The mic track will still be saved.")
        }
    }

    struct StopResult: Sendable {
        let durationSeconds: Double
        /// True iff `system.caf` got at least one buffer written. False on
        /// a fully-silent meeting where nothing played through speakers.
        let didCaptureSystem: Bool
    }

    /// Stop SCStream and close the system file. Safe to call multiple times.
    func stop() async -> StopResult {
        guard running else { return StopResult(durationSeconds: 0, didCaptureSystem: false) }
        running = false
        bringUpWatchdog?.cancel()
        bringUpWatchdog = nil
        let s = stream
        stream = nil
        output = nil
        if let s {
            try? await s.stopCapture()
        }
        let hadSystem = systemFile != nil
        systemFile = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return StopResult(durationSeconds: duration, didCaptureSystem: hadSystem)
    }

    // MARK: - Sample ingest (called from non-main queues)

    fileprivate nonisolated func ingest(
        audio sampleBuffer: CMSampleBuffer,
        type: SCStreamOutputType,
        sink: (@Sendable (CMSampleBuffer) -> Void)?
    ) {
        // Fire the optional raw-buffer sink first, off-main, so the live
        // transcriber can start its conversion on the audio queue while
        // we're still building the resampled mono Float32 for disk. The
        // sink contract documents that it runs on this queue and is
        // responsible for any actor hop of its own. The sink is snapshotted
        // by the forwarder at start time so we never have to cross the
        // MainActor isolation barrier to read it.
        if type == .audio, let sink {
            sink(sampleBuffer)
        }
        guard let (samples, format) = Self.extractPCM(from: sampleBuffer, type: type) else { return }
        let level = Self.rms(samples: samples)

        // First-audio-buffer probe: log once per recording. Guarded by
        // the same lock the watchdog reads under, on the audio queue.
        if type == .audio {
            let wasFirst = firstAudioBufferFlag.withLock { seen -> Bool in
                guard !seen else { return false }
                seen = true
                return true
            }
            if wasFirst {
                NSLog("[Dictator] MeetingSystem: first audio buffer — format=\(format.sampleRate)/\(format.channelCount), frames=\(samples.count), rmsLevel=\(level)")
            }
        }

        Task { @MainActor [weak self] in
            self?.write(samples: samples, format: format, type: type, level: level)
        }
    }

    @MainActor
    private func write(samples: [Float], format: AVAudioFormat, type: SCStreamOutputType, level: Float) {
        guard running else { return }
        guard type == .audio else { return }
        do {
            if systemFile == nil, let url = systemURL {
                systemFile = try Self.openFile(at: url, source: format)
            }
            if let file = systemFile {
                try Self.append(samples: samples, format: format, to: file)
            }
            lastSystemLevel = level
        } catch {
            NSLog("[Dictator] write(system) failed: \(error)")
        }
        onLevel?(0, lastSystemLevel)
    }

    // MARK: - File helpers

    /// Open a CAF (Core Audio Format) file at `url` for streaming writes.
    /// CAF is crash-safe by design: its `data` chunk is written with a
    /// sentinel `-1` length meaning "read to end of file", so a truncated
    /// CAF from a crashed recorder is still fully decodable. MP4/M4A is
    /// the opposite — the `moov` atom that holds the sample table is
    /// written only at file close, so a crash mid-recording leaves the
    /// container unreadable even though the AAC bytes themselves are on
    /// disk. The trade-off is larger files (LinearPCM Float32 mono at the
    /// source rate is ~700 MB/hour) versus 100% recoverability.
    private static func openFile(at url: URL, source: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func append(samples: [Float], format: AVAudioFormat, to file: AVAudioFile) throws {
        // Build a non-interleaved Float32 mono buffer (downmix happens in
        // `extractPCM`) at the source rate. AVAudioFile.write transparently
        // resamples to the target rate if needed.
        guard let sourceMono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: sourceMono, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src -> Void in
                memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
            }
        }
        try file.write(from: buffer)
    }

    // MARK: - Sample extraction (off-main)

    /// Pull mono Float32 samples + the source format out of a CMSampleBuffer
    /// produced by SCStream. SCK delivers planar / interleaved Float32 or
    /// Int16 depending on configuration; we asked for Float32 above but
    /// guard against either shape for safety.
    private nonisolated static func extractPCM(from sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) -> ([Float], AVAudioFormat)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return nil }

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        // SCK delivers audio either as interleaved or non-interleaved
        // depending on the source. mFormatFlags bit 0x20 = non-interleaved.
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return nil }
        let totalFloats = totalLength / MemoryLayout<Float>.size

        var mono = [Float](repeating: 0, count: frameCount)
        let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)

        if channels == 1 {
            let buf = UnsafeBufferPointer(start: floats, count: min(totalFloats, frameCount))
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                memcpy(dst.baseAddress!, buf.baseAddress!, buf.count * MemoryLayout<Float>.size)
            }
        } else if isNonInterleaved {
            // Each channel occupies a contiguous run of `frameCount` floats.
            let invChannels = 1 / Float(channels)
            mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                for f in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += floats[c * frameCount + f]
                    }
                    base[f] = sum * invChannels
                }
            }
        } else {
            // Interleaved: frame 0 channel 0, frame 0 channel 1, frame 1 ch 0, …
            guard totalFloats >= frameCount * channels else { return nil }
            let buf = UnsafeBufferPointer(start: floats, count: frameCount * channels)
            let invChannels = 1 / Float(channels)
            mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                for f in 0..<frameCount {
                    var sum: Float = 0
                    let frameStart = f * channels
                    for c in 0..<channels { sum += buf[frameStart + c] }
                    base[f] = sum * invChannels
                }
            }
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        return (mono, format)
    }

    private nonisolated static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var v: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &v, vDSP_Length(samples.count))
        }
        return min(1, max(0, sqrtf(v) * 2.5))
    }

    private static let audioQueue = DispatchQueue(label: "Dictator.MeetingAudio.audio", qos: .userInitiated)
    private static let videoQueue = DispatchQueue(label: "Dictator.MeetingAudio.video", qos: .background)
}

/// Adopts SCK's two delegate protocols. `@unchecked Sendable` because SCK
/// invokes the methods on its sample-handler queues — the closure body hops
/// straight back to the main actor before touching any owner state.
private final class StreamOutputForwarder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    weak var owner: MeetingAudioRecorder?
    /// Snapshot of `MeetingAudioRecorder.onBuffer` taken at start. Holding
    /// it on the (`@unchecked Sendable`) forwarder lets the audio queue
    /// invoke it without ever crossing the main-actor isolation barrier
    /// to read it back off the recorder. Set once, never reassigned.
    let bufferSink: (@Sendable (CMSampleBuffer) -> Void)?

    init(
        owner: MeetingAudioRecorder,
        bufferSink: (@Sendable (CMSampleBuffer) -> Void)?
    ) {
        self.owner = owner
        self.bufferSink = bufferSink
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            owner?.ingest(audio: sampleBuffer, type: type, sink: bufferSink)
        default:
            // .screen (required by SCK but discarded) and .microphone
            // (we don't request it — mic capture lives in MeetingMicRecorder).
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let msg = error.localizedDescription
        NSLog("[Dictator] SCStream didStopWithError: \(error)")
        Task { @MainActor [weak owner] in
            owner?.onUnexpectedStop?("Screen capture stopped: \(msg)")
        }
    }
}
