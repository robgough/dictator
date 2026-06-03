import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import os

/// Thin NSObject shim bridging `AVCaptureAudioDataOutput`'s Objective-C
/// delegate to a Swift closure — same shape as the dictation recorder's
/// `SampleBufferForwarder`. `@unchecked Sendable` because AVCapture only
/// invokes the delegate from its configured queue and the closure does its
/// own actor hop.
private final class SampleBufferForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

/// Captures mic audio for a meeting via `AVCaptureSession` and writes it
/// directly to a CAF file as the buffers arrive. Runs alongside the
/// `MeetingAudioRecorder` (CoreAudio process-tap system audio) on its own
/// capture session so the two tracks are independent.
///
/// Why AVCaptureSession and not AVAudioEngine? This recorder used to run on
/// AVAudioEngine purely to get `setVoiceProcessingEnabled(true)` (macOS's
/// built-in acoustic echo cancellation). That turned out to be unworkable:
/// the AVAudioEngine input path can't negotiate the format of common USB
/// mics — a Blue Yeti throws `-10868` (input HW 48 kHz vs a 192 kHz tap
/// format) and never starts at all — and when voice processing *does* come
/// up on an input-only graph it floods the AEC downlink DSP with I/O faults
/// and times out waiting for streams, so capture dies partway through. The
/// dictation recorder deliberately uses AVCaptureSession precisely because
/// it handles "USB devices that share clock with the output (Yeti, audio
/// interfaces)" cleanly, so the meeting mic now uses the same stack. Remote-
/// speaker bleed (the reason AEC was wanted) is removed after the fact by
/// `MeetingProcessor.dedupeMicEchoes`, gated by the "Drop echoes captured by
/// my microphone" setting.
///
/// Writes LinearPCM Int16 mono to a `.caf` file at the device's native
/// sample rate. CAF is crash-safe (its data chunk uses a "-1 = read to end"
/// length sentinel); a truncated file from a Dictator crash is still fully
/// decodable up to the last buffer that hit disk. Once the post-pass has the
/// transcript, `MeetingAudioCompactor` re-encodes the track to AAC in place.
@MainActor
final class MeetingMicRecorder {
    /// The live capture session, set once `adopt` accepts a started session
    /// from the off-main setup task. Nil between `stop()` and the next start.
    private var session: AVCaptureSession?
    /// Strong reference to the delegate — `AVCaptureAudioDataOutput` only
    /// weakly retains it.
    private var sampleForwarder: SampleBufferForwarder?
    /// Notification observers tied to the live session's lifecycle.
    private var observers: [NSObjectProtocol] = []
    /// Dedicated queue the capture output delivers buffers on.
    private let outputQueue = DispatchQueue(label: "Dictator.MeetingMic.output", qos: .userInitiated)

    private var running = false
    /// Generation counter so a session whose off-main setup is still in
    /// flight when the user stops (or a fallback supersedes it) doesn't get
    /// adopted after the fact.
    private var startGeneration = 0

    private var file: AVAudioFile?
    private(set) var fileURL: URL?
    /// True once at least one buffer made it to disk.
    private(set) var didCapture = false

    /// Flipped on the capture queue the moment the first buffer lands; read
    /// by the silent-capture watchdog on the main actor. `OSAllocatedUnfairLock`
    /// is the async-safe primitive — `NSLock.lock()` traps from an async
    /// context under Swift 6 strict concurrency.
    private let firstBufferFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var silentCaptureTask: Task<Void, Never>?

    /// 0…1 RMS reported on the main actor for every captured buffer.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Fires once per recording with a human-readable reason the mic capture
    /// looks unhealthy (couldn't start, no buffers, device disconnected). The
    /// session pipes this into its `captureWarnings` banner. Mic trouble is
    /// non-fatal — the system track alone is still a useful meeting.
    var onCaptureWarning: (@MainActor (String) -> Void)?

    /// Optional sink for captured mic audio as mono Float32 at the device's
    /// native sample rate, fired alongside the on-disk write. The live-
    /// transcript service hangs off this to resample + chunk for Parakeet.
    /// **Fires on the capture queue, not the main actor** — the callee does
    /// its own actor hop. Snapshotted into the delegate closure at start;
    /// reassigning after `start` won't affect an in-flight session.
    var onBuffer: (@Sendable (_ mono: [Float], _ sampleRate: Double) -> Void)?

    init() {}

    /// Begin capturing the user's preferred input device to `url`. Returns
    /// once setup has been kicked off — the actual device resolution and
    /// `AVCaptureSession` build run off-main (those CoreAudio touches can
    /// briefly block when coreaudiod is busy). Mic startup failure is
    /// reported via `onCaptureWarning`, never thrown: a meeting with only the
    /// system track is still worth keeping. Falls back to the system-default
    /// input if the preferred device can't be attached.
    func start(at url: URL, preferredDevice: AudioDevice?) async {
        guard !running else { return }
        running = true
        fileURL = url
        try? FileManager.default.removeItem(at: url)
        didCapture = false
        file = nil
        firstBufferFlag.withLock { $0 = false }
        startGeneration &+= 1
        let generation = startGeneration

        let label = preferredDevice.map { $0.isSystemDefault ? "<system default>" : $0.uid } ?? "<nil / system default>"
        NSLog("[Dictator] MeetingMic: starting (AVCaptureSession) — preferredDevice=\(label)")

        // Snapshot the UID on main; the expensive `AVCaptureDevice(uniqueID:)`
        // lookup moves off-main like the dictation recorder does.
        let uid = preferredDevice.flatMap { $0.isSystemDefault ? nil : $0.uid }
        Task.detached(priority: .userInitiated) { [weak self] in
            let device = Self.resolveCaptureDevice(uid: uid)
            await self?.startSession(device: device, allowDefaultFallback: true, generation: generation)
        }
    }

    /// Stop capture and close the file. Safe to call multiple times.
    func stop() async {
        startGeneration &+= 1
        guard running else { return }
        running = false
        silentCaptureTask?.cancel()
        silentCaptureTask = nil
        teardownSession()
        // Drop the file last so any in-flight `write` hop finds running ==
        // false and bails before touching it. Releasing the AVAudioFile
        // flushes it to disk.
        file = nil
    }

    // MARK: - Session setup

    /// Build and start an `AVCaptureSession` for `device` off-main, then hand
    /// it to `adopt` on the main actor. On a setup failure, retries once
    /// against the system default (when `allowDefaultFallback`), else warns.
    private func startSession(device: AVCaptureDevice?, allowDefaultFallback: Bool, generation: Int) {
        guard generation == startGeneration, running else { return }
        guard let device else {
            running = false
            onCaptureWarning?("Dictator couldn't find a microphone to record. Pick an input device in Settings, then start the meeting again.")
            return
        }

        // Snapshot the buffer sink + first-buffer flag on main so the capture
        // queue never reads main-actor state directly.
        let bufferSink = onBuffer
        let firstBufferFlag = self.firstBufferFlag
        let forwarder = SampleBufferForwarder { [weak self] sampleBuffer in
            guard let processed = Self.processSampleBuffer(sampleBuffer) else { return }
            let wasFirst = firstBufferFlag.withLock { seen -> Bool in
                guard !seen else { return false }
                seen = true
                return true
            }
            if wasFirst {
                NSLog("[Dictator] MeetingMic: first buffer — rate=\(processed.sampleRate), frames=\(processed.mono.count)")
            }
            bufferSink?(processed.mono, processed.sampleRate)
            Task { @MainActor [weak self, processed] in
                self?.write(samples: processed.mono, sampleRate: processed.sampleRate, level: processed.level)
            }
        }
        let queue = outputQueue

        Task.detached(priority: .userInitiated) { [weak self] in
            let session = AVCaptureSession()
            session.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    throw NSError(domain: "Dictator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Couldn't attach \(device.localizedName) to the capture session."])
                }
                session.addInput(input)

                let output = AVCaptureAudioDataOutput()
                // Interleaved Float32 PCM — one CMBlockBuffer, samples laid
                // out frame-by-frame. We downmix to mono ourselves and let
                // the device keep its native rate (44.1 / 48 / 96 kHz …).
                output.audioSettings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                output.setSampleBufferDelegate(forwarder, queue: queue)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NSError(domain: "Dictator", code: -3, userInfo: [NSLocalizedDescriptionKey: "Couldn't attach the audio output to the capture session."])
                }
                session.addOutput(output)

                session.commitConfiguration()
                session.startRunning()
            } catch {
                await self?.handleSetupFailure(device: device, allowDefaultFallback: allowDefaultFallback, generation: generation, error: error)
                return
            }
            await self?.adopt(session: session, forwarder: forwarder, generation: generation)
        }
    }

    /// Main-actor completion for a successful off-main setup. Discards the
    /// session if the generation moved on (stopped / superseded mid-warmup).
    private func adopt(session newSession: AVCaptureSession, forwarder: SampleBufferForwarder, generation: Int) {
        guard generation == startGeneration, running else {
            Self.stopSessionAsync(newSession)
            return
        }
        session = newSession
        sampleForwarder = forwarder
        installObservers(for: newSession)
        NSLog("[Dictator] MeetingMic: capture session running")
        startSilentCaptureWatchdog()
    }

    private func handleSetupFailure(device: AVCaptureDevice, allowDefaultFallback: Bool, generation: Int, error: Error) {
        guard generation == startGeneration, running else { return }
        NSLog("[Dictator] MeetingMic: capture setup failed for \(device.localizedName): \(error)")
        if allowDefaultFallback {
            startGeneration &+= 1
            let next = startGeneration
            Task.detached(priority: .userInitiated) { [weak self] in
                let fallback = AVCaptureDevice.default(for: .audio)
                await self?.startSession(device: fallback, allowDefaultFallback: false, generation: next)
            }
        } else {
            running = false
            onCaptureWarning?("Dictator couldn't start the microphone capture. The recording will continue but the mic track may be empty. Try a different input device in Settings.")
        }
    }

    // MARK: - Runtime observation

    private func installObservers(for session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
            MainActor.assumeIsolated {
                self?.handleMicLost("Microphone capture failed: \(detail). The mic track stops here; the rest of the meeting keeps recording.")
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let device = note.object as? AVCaptureDevice
            let uniqueID = device?.uniqueID
            let localizedName = device?.localizedName ?? "Microphone"
            MainActor.assumeIsolated {
                guard let self, let uniqueID, self.running else { return }
                let inputDevices = (self.session?.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }) ?? []
                guard inputDevices.contains(where: { $0.uniqueID == uniqueID }) else { return }
                self.handleMicLost("\(localizedName) was disconnected. The mic track stops here; the rest of the meeting keeps recording.")
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMicLost("Microphone capture was interrupted. The mic track stops here; the rest of the meeting keeps recording.")
            }
        })
    }

    private func teardownObservers() {
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    private func teardownSession() {
        teardownObservers()
        silentCaptureTask?.cancel()
        silentCaptureTask = nil
        if let s = session {
            Self.stopSessionAsync(s)
        }
        session = nil
        sampleForwarder = nil
    }

    /// `stopRunning()` can block briefly (BT HFP teardown); move it off-main
    /// so a stop doesn't beachball the UI. Safe to let the detached task own
    /// the session once we've dropped our reference.
    private nonisolated static func stopSessionAsync(_ session: AVCaptureSession) {
        Task.detached { session.stopRunning() }
    }

    /// Mic capture died mid-meeting. Close it down and warn, but leave the
    /// already-written CAF intact and let the meeting (system track) continue.
    private func handleMicLost(_ message: String) {
        guard running else { return }
        running = false
        teardownSession()
        file = nil
        NSLog("[Dictator] MeetingMic: \(message)")
        onCaptureWarning?(message)
    }

    // MARK: - Silent-capture watchdog

    /// `startRunning()` can return having declared itself running without
    /// ever delivering a sample buffer (device held exclusively by another
    /// app, USB device stuck mid-init). After 3 s with no buffer, warn — but
    /// keep the session up in case it recovers, since the file write opens
    /// lazily on the first buffer either way.
    private func startSilentCaptureWatchdog() {
        silentCaptureTask?.cancel()
        silentCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.running else { return }
            let sawBuffer = self.firstBufferFlag.withLock { $0 }
            guard !sawBuffer else { return }
            NSLog("[Dictator] MeetingMic: no buffers after 3s — surfacing warning")
            self.onCaptureWarning?("Dictator isn't receiving any microphone audio. Check that the right input device is selected and that nothing else is holding the mic exclusively.")
        }
    }

    // MARK: - File writing

    @MainActor
    private func write(samples: [Float], sampleRate: Double, level: Float) {
        guard running, let url = fileURL else { return }
        do {
            if file == nil {
                file = try Self.openFile(at: url, sampleRate: sampleRate)
            }
            guard let file else { return }
            // A mid-recording device swap can bring back a different native
            // rate. AVAudioFile won't accept a buffer whose rate disagrees
            // with how it was opened; rather than corrupt the CAF, drop the
            // buffer and keep the existing recording.
            guard abs(file.fileFormat.sampleRate - sampleRate) < 1 else {
                onLevel?(level)
                return
            }
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let dst = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src -> Void in
                    memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
                }
            }
            try file.write(from: buffer)
            didCapture = true
        } catch {
            NSLog("[Dictator] MeetingMicRecorder write failed: \(error)")
        }
        onLevel?(level)
    }

    /// Int16 PCM on disk (buffers stay Float32 in memory; AVAudioFile
    /// converts on write). 16-bit is already beyond what a meeting mic
    /// resolves and halves the bytes vs Float32; `MeetingAudioCompactor`
    /// re-encodes the track to AAC once the post-pass is done with it.
    private static func openFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    // MARK: - Device resolution

    /// Resolve a saved UID to a live `AVCaptureDevice`. nil UID (the "System
    /// default" sentinel, or nothing saved) → `AVCaptureDevice.default`.
    /// `AVCaptureDevice.uniqueID` matches CoreAudio's device UID for real
    /// hardware, so the look-up just works.
    private nonisolated static func resolveCaptureDevice(uid: String?) -> AVCaptureDevice? {
        guard let uid else { return AVCaptureDevice.default(for: .audio) }
        return AVCaptureDevice(uniqueID: uid) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Sample buffer ingest

    private struct Processed: Sendable {
        let mono: [Float]
        let level: Float
        let sampleRate: Double
    }

    /// Extract mono Float32 + an RMS level from an interleaved-Float32
    /// `CMSampleBuffer`. Mirrors the dictation recorder's `processSampleBuffer`.
    private nonisolated static func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Processed? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return nil }

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

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
        // Defensive: should be exactly frameCount * channels floats.
        guard totalFloats == frameCount * channels else { return nil }

        let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        let buffer = UnsafeBufferPointer(start: floats, count: totalFloats)

        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                memcpy(dst.baseAddress!, buffer.baseAddress!, frameCount * MemoryLayout<Float>.size)
            }
        } else {
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                let base = dst.baseAddress!
                let invChannels = 1 / Float(channels)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    let frameStart = i * channels
                    for c in 0..<channels { sum += buffer[frameStart + c] }
                    base[i] = sum * invChannels
                }
            }
        }

        var rms: Float = 0
        mono.withUnsafeBufferPointer { ptr -> Void in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(frameCount))
        }
        // Square-root mapping onto [0,1] — same as the dictation recorder;
        // linear scaling collapses quieter mics below the meter floor.
        let level = min(1, max(0, sqrtf(rms) * 2.5))
        return Processed(mono: mono, level: level, sampleRate: sampleRate)
    }
}
