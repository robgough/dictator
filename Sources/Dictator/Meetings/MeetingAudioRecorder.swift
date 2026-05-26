import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import ScreenCaptureKit
import AppKit

/// Captures mic + system audio for one meeting via ScreenCaptureKit. Writes
/// two AAC-encoded `.m4a` files (mic.m4a, system.m4a) into the meeting's
/// folder.
///
/// Sibling to `Audio/AudioRecorder.swift` — they share concepts (sample
/// extraction, level metering) but the underlying capture surface is
/// completely different. AudioRecorder uses AVCaptureSession for the mic
/// only; this class uses SCStream so it can grab system audio at the same
/// time. macOS 15+ added `captureMicrophone` to SCStream which lets one
/// session deliver both tracks via separate `SCStreamOutputType` channels.
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
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var running = false

    /// Where the recorder writes. Populated by `start(folder:)` and held so
    /// the file URLs survive across SCStream's async lifecycle.
    private(set) var micURL: URL?
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Fired once both files exist and the stream is producing buffers.
    /// The session's "warmingUp" → "recording" pivot hangs off this.
    var onReady: (@MainActor () -> Void)?

    /// Fired on each successful sample-buffer ingest with the current mic
    /// + system RMS levels. Each on a 0…1 scale; either may be 0 if that
    /// track hasn't produced a buffer yet.
    var onLevel: (@MainActor (_ mic: Float, _ system: Float) -> Void)?

    /// Fired if SCStream stops itself outside our control (user revoked
    /// the grant mid-recording, display went to sleep on system sleep
    /// without us holding an idle assertion). Recorder is left torn down.
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0

    init() {}

    /// Build the SCStream, open both AVAudioFiles lazily on first sample,
    /// and begin capture. Throws on permission denied, content-filter
    /// failure, or AVAudioFile setup. The meta.json is the session's
    /// responsibility, not ours.
    func start(folder: URL, preferredMicUID: String?) async throws {
        guard !running else { return }

        let micPath = folder.appendingPathComponent(MeetingStorage.micFilename)
        let systemPath = folder.appendingPathComponent(MeetingStorage.systemFilename)
        self.micURL = micPath
        self.systemURL = systemPath
        try? FileManager.default.removeItem(at: micPath)
        try? FileManager.default.removeItem(at: systemPath)

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
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

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        if let preferredMicUID, !preferredMicUID.isEmpty {
            config.microphoneCaptureDeviceID = preferredMicUID
        }
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Self.channelCount
        // Minimum-cost video stream — SCK requires it, but we drop every
        // .screen sample on arrival.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let forwarder = StreamOutputForwarder(owner: self)
        try stream.addStreamOutput(forwarder, type: .audio, sampleHandlerQueue: Self.audioQueue)
        try stream.addStreamOutput(forwarder, type: .microphone, sampleHandlerQueue: Self.audioQueue)
        try stream.addStreamOutput(forwarder, type: .screen, sampleHandlerQueue: Self.videoQueue)

        try await stream.startCapture()

        self.stream = stream
        self.output = forwarder
        self.running = true
        self.startedAt = Date()
        onReady?()
    }

    /// Stop capture and close both files. Safe to call multiple times.
    /// Returns the captured duration in seconds (0 if start never happened).
    func stop() async -> Double {
        guard running else { return 0 }
        running = false
        let s = stream
        stream = nil
        output = nil
        if let s {
            try? await s.stopCapture()
        }
        // Closing AVAudioFile flushes any buffered samples; nil-out to
        // release the file handles before the session updates meta.json.
        micFile = nil
        systemFile = nil
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Sample ingest (called from non-main queues)

    fileprivate nonisolated func ingest(audio sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard let (samples, format) = Self.extractPCM(from: sampleBuffer) else { return }
        let level = Self.rms(samples: samples)
        Task { @MainActor [weak self] in
            self?.write(samples: samples, format: format, type: type, level: level)
        }
    }

    @MainActor
    private func write(samples: [Float], format: AVAudioFormat, type: SCStreamOutputType, level: Float) {
        guard running else { return }
        do {
            switch type {
            case .audio:
                if systemFile == nil, let url = systemURL {
                    systemFile = try Self.openFile(at: url, source: format)
                }
                if let file = systemFile {
                    try Self.append(samples: samples, format: format, to: file)
                }
                lastSystemLevel = level
            case .microphone:
                if micFile == nil, let url = micURL {
                    micFile = try Self.openFile(at: url, source: format)
                }
                if let file = micFile {
                    try Self.append(samples: samples, format: format, to: file)
                }
                lastMicLevel = level
            default:
                return
            }
        } catch {
            // Best-effort: a single failed write shouldn't tear the whole
            // recording down — surface via onUnexpectedStop only if the
            // file handle itself is gone.
            NSLog("[Dictator] MeetingAudioRecorder write failed: \(error)")
        }
        onLevel?(lastMicLevel, lastSystemLevel)
    }

    // MARK: - File helpers

    /// Open an AAC-encoded `.m4a` file at `url` whose decoded format
    /// matches `source`. We pass AAC settings in `AVAudioFile(forWriting:)`
    /// — the file then transparently encodes incoming Float32 buffers via
    /// CoreAudio's AAC encoder. 96 kbps mono is plenty for ASR and lands
    /// a 2-hour meeting under ~170 MB.
    private static func openFile(at url: URL, source: AVAudioFormat) throws -> AVAudioFile {
        // Force mono output — both Parakeet and the level meter want mono,
        // and downmixing on write keeps the disk file half the size.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
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
    private nonisolated static func extractPCM(from sampleBuffer: CMSampleBuffer) -> ([Float], AVAudioFormat)? {
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

    init(owner: MeetingAudioRecorder) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio, .microphone:
            owner?.ingest(audio: sampleBuffer, type: type)
        case .screen:
            // Discard. SCK requires a video stream but we don't need it.
            return
        @unknown default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let msg = error.localizedDescription
        Task { @MainActor [weak owner] in
            owner?.onUnexpectedStop?("Screen capture stopped: \(msg)")
        }
    }
}
