import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia

private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}

/// Thin NSObject shim that bridges AVCaptureAudioDataOutput's
/// Objective-C delegate protocol to a Swift closure. Lets `AudioRecorder`
/// stay a plain `final class` rather than inheriting NSObject just to
/// adopt one delegate method. Marked `@unchecked Sendable` because the
/// AVCapture machinery only invokes the delegate from its configured
/// queue; the closure handles the actor hop itself.
private final class SampleBufferForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

/// Microphone capture, built on AVCaptureSession.
///
/// Why AVCaptureSession and not AVAudioEngine? Capture-only workloads sit
/// awkwardly inside AVAudioEngine's audio-graph model — every recording
/// pays for the graph machinery (AUHAL device-property overrides, tap
/// format propagation, ConfigurationChange rebuilds) without using it.
/// In practice that machinery is *also* the source of most of the
/// flakiness we see: USB devices that share clock with the output (Yeti,
/// audio interfaces) get silently knocked into stale formats when system
/// audio output changes, and the engine's catch-all ConfigurationChange
/// notification doesn't always fire for those subtle clock shifts.
///
/// AVCaptureSession is the AVFoundation media-capture stack — same one
/// Apple's speech-recognition samples and most macOS recording apps use.
/// It's designed around "this device → give me samples; handle
/// reconfiguration internally", with dedicated notifications for runtime
/// errors and device disconnects, and an explicit
/// beginConfiguration/commitConfiguration model for hot-swaps. We get a
/// stream of `CMSampleBuffer`s on a delegate queue; everything else (mono
/// downmix, level metering, 16 kHz resample for WhisperKit) is ours.
@MainActor
final class AudioRecorder {
    private let targetSampleRate: Double = 16_000
    private var rawBuffer: [Float] = []         // mono, at native sample rate
    private var nativeSampleRate: Double = 0    // populated from the first CMSampleBuffer
    private var running = false
    private var startInFlight = false

    /// Generation counter so a Bluetooth start still in HFP negotiation
    /// when the user releases the hotkey doesn't end up adopting its
    /// session after we've already returned to .idle. Bumped by `start`,
    /// `stop`, `cancelStart`, and on each retry path inside
    /// `handleStartFailure`.
    private var startGeneration: Int = 0

    /// The live session, set once `adoptSession` accepts a started session
    /// from the off-main setup task. Nil between `stop()` and the next
    /// successful start.
    private var session: AVCaptureSession?
    /// Strong reference to the delegate object — AVCaptureAudioDataOutput
    /// only weakly retains it.
    private var sampleForwarder: SampleBufferForwarder?
    /// Notification observers tied to the live session's lifecycle.
    private var observers: [NSObjectProtocol] = []
    /// Dedicated dispatch queue the capture output delivers buffers on.
    /// Reused across recordings.
    private let outputQueue = DispatchQueue(label: "Dictator.AudioRecorder.output", qos: .userInitiated)

    /// Most-recent time a CMSampleBuffer made it back to the main actor.
    /// The silent-capture watchdog uses this to spot the rare case where
    /// AVCaptureSession.startRunning() returns but no audio actually
    /// flows (device claimed exclusively by another app, BT device whose
    /// HFP negotiation half-failed, etc.).
    private var lastBufferTime: Date?
    private var silentCaptureTask: Task<Void, Never>?

    /// 0...1 RMS reported on the main actor.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Per-buffer mono samples at the device's native sample rate, alongside
    /// that rate so the consumer can wrap them in an AVAudioPCMBuffer of the
    /// correct format. Used by the Parakeet streaming path to feed FluidAudio
    /// live during recording. Fires on the same main-actor hop as `onLevel`,
    /// after the buffer has been appended to `rawBuffer`, so the final samples
    /// at `stop()` always include every interim chunk too.
    var onInterimSamples: (@MainActor ([Float], Double) -> Void)?

    /// Fired once the capture session is genuinely producing audio. On
    /// Bluetooth mics this can be 2–5 s after `start()` returns —
    /// callers should reflect "warming up" in their UI until then.
    var onReady: (@MainActor () -> Void)?

    /// Fired if session startup fails outright (mic permission denied at
    /// the OS level, the chosen device couldn't be added to the session,
    /// no input device at all, or the warm-up / silent-capture watchdog
    /// gave up). The recorder is left in a stopped state.
    var onStartFailed: (@MainActor (Error) -> Void)?

    /// Fired if capture is lost while running — runtime error from
    /// CoreAudio, the active input device was disconnected, or session
    /// was interrupted. The recorder stops itself first.
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    init() {}

    /// Kick off session startup. Returns immediately — every CoreAudio /
    /// AVFoundation touch (device resolution, BT probe, session build,
    /// `startRunning()`) runs off-main. Keeping the main actor free is
    /// load-bearing for the warmup watchdog: it's an async `Task @MainActor`
    /// that needs to actually run when its sleep ends, which it can't do
    /// if main is mid-CoreAudio query. Caller is notified via `onReady`
    /// (success) or `onStartFailed` (failure), both on the main actor.
    func start() {
        guard !running, !startInFlight else { return }
        rawBuffer.removeAll(keepingCapacity: true)
        nativeSampleRate = 0
        lastBufferTime = nil

        startInFlight = true
        startGeneration &+= 1
        let generation = startGeneration

        // Snapshot the user's preferred device on main (cheap dict read on
        // an @Observable @MainActor object — has to happen here). Everything
        // expensive — `AVCaptureDevice(uniqueID:)`, the UID→AudioDeviceID
        // translation, the BT-transport query — moves to the detached task.
        // Those CoreAudio touches can briefly block when coreaudiod is busy
        // (USB / Thunderbolt mic just woke, recent default-input swap), and
        // when they blocked on main, the warmup watchdog couldn't fire —
        // that was the "Connecting microphone" hang we couldn't shake.
        let preferred = AudioDeviceManager.shared.preferredConnectedDevice()
        Task.detached(priority: .userInitiated) { [weak self] in
            let device = Self.resolveCaptureDevice(preferred: preferred)
            let isBT = Self.isBluetoothDevice(device)
            await self?.continueStartOnMain(device: device, isBT: isBT, generation: generation)
        }
    }

    /// Main-actor continuation of `start()` after off-main device resolution.
    /// Bails if the generation has moved on (user released the hotkey, or a
    /// concurrent start raced us). Picks the timeout / retry policy from the
    /// device's BT-ness, then hands off to the existing per-attempt setup.
    private func continueStartOnMain(device: AVCaptureDevice?, isBT: Bool, generation: Int) {
        guard generation == startGeneration else { return }
        // Pick a timeout (and retry policy) based on device type. Bluetooth
        // legitimately takes 3–5 s for HFP negotiation on the first open,
        // so it gets the generous budget. Wired devices (USB, built-in)
        // should be sub-second; a multi-second wait there usually means
        // CoreAudio is wedged on a transient glitch — those clear cleanly
        // on a same-device retry, which is much more user-visible than
        // falling straight back to the system default.
        let timeout: Double = isBT ? 6 : Self.wiredWarmupTimeoutSeconds
        let sameDeviceRetries = isBT ? 0 : 1
        startSessionAsync(
            device: device,
            allowDefaultFallback: true,
            sameDeviceRetriesRemaining: sameDeviceRetries,
            generation: generation,
            timeoutSeconds: timeout
        )
    }

    /// Timeout budget for wired devices (USB, built-in). Short because a
    /// healthy `startRunning()` on those returns in well under a second;
    /// the sub-3-second window catches genuine hangs while still allowing
    /// some headroom for first-touch CoreAudio bring-up.
    private static let wiredWarmupTimeoutSeconds: Double = 2.5

    /// True when the AVCaptureDevice's underlying CoreAudio device reports
    /// a Bluetooth transport. We bridge via the device UID since
    /// AVCaptureDevice itself doesn't expose transport type for audio.
    /// Nonisolated so the detached startup task can run it off-main —
    /// the underlying CoreAudio property query is one of the calls that
    /// previously froze main on a busy coreaudiod.
    private nonisolated static func isBluetoothDevice(_ device: AVCaptureDevice?) -> Bool {
        guard let device,
              let coreAudioID = AudioDeviceEnumerator.deviceID(forUID: device.uniqueID)
        else { return false }
        return AudioDeviceEnumerator.isBluetooth(deviceID: coreAudioID)
    }

    /// Abort an in-flight startup. The async setup task still runs to
    /// completion (we can't preempt CoreAudio negotiation), but its
    /// completion handler discards the session instead of adopting it.
    /// Safe to call when no startup is in flight.
    func cancelStart() {
        startGeneration &+= 1
        startInFlight = false
    }

    /// Stop capture and return 16 kHz mono Float32 samples ready for
    /// WhisperKit. All sample-rate conversion happens here on the main
    /// actor, off the capture queue. Safe to call multiple times; later
    /// calls return an empty array.
    func stop() -> [Float] {
        startGeneration &+= 1
        startInFlight = false
        if running {
            teardownSession()
            running = false
        }
        silentCaptureTask?.cancel()
        silentCaptureTask = nil

        let nativeSamples = rawBuffer
        let rate = nativeSampleRate
        rawBuffer.removeAll(keepingCapacity: false)

        guard rate > 0 else { return nativeSamples }
        return Self.resampleToTarget(monoSamples: nativeSamples, fromSampleRate: rate, toSampleRate: targetSampleRate)
            ?? nativeSamples
    }

    // MARK: - Setup pipeline

    private func startSessionAsync(
        device: AVCaptureDevice?,
        allowDefaultFallback: Bool,
        sameDeviceRetriesRemaining: Int,
        generation: Int,
        timeoutSeconds: Double
    ) {
        guard let device else {
            startInFlight = false
            onStartFailed?(NSError(
                domain: "Dictator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone available."]
            ))
            return
        }

        // Forwarder closes over `generation` so any samples it delivers
        // are tagged with the start they came from. If the user cancels or
        // we retry, samples from the stale generation get dropped on main.
        let capturedGeneration = generation
        let forwarder = SampleBufferForwarder { [weak self] sampleBuffer in
            guard let processed = Self.processSampleBuffer(sampleBuffer) else { return }
            Task { @MainActor [weak self, processed, capturedGeneration] in
                guard let self else { return }
                guard self.startGeneration == capturedGeneration else { return }
                self.appendSamples(
                    mono: processed.mono,
                    level: processed.level,
                    sampleRate: processed.sampleRate
                )
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
                    throw NSError(
                        domain: "Dictator",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Couldn't attach \(device.localizedName) to the capture session."]
                    )
                }
                session.addInput(input)

                let output = AVCaptureAudioDataOutput()
                // Interleaved Float32 PCM keeps the per-buffer extraction
                // simple — one CMBlockBuffer, samples laid out frame-by-
                // frame with channels grouped. Sample rate and channel
                // count are left to the device; we downmix and resample
                // ourselves at stop time so the device can use whatever
                // it likes natively (usually 44.1 / 48 / 96 kHz).
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
                    throw NSError(
                        domain: "Dictator",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Couldn't attach the audio output to the capture session."]
                    )
                }
                session.addOutput(output)

                session.commitConfiguration()
                // startRunning blocks until the session is producing
                // samples. On BT this includes HFP profile negotiation;
                // on USB it's near-instant unless the device is held by
                // another app — that case is what the watchdog below
                // catches.
                session.startRunning()
            } catch {
                await self?.handleStartFailure(
                    error: error,
                    allowDefaultFallback: allowDefaultFallback,
                    generation: generation
                )
                return
            }

            await self?.adoptSession(
                session: session,
                forwarder: forwarder,
                generation: generation
            )
        }

        // Warmup watchdog. CoreAudio occasionally blocks indefinitely
        // inside startRunning — USB device claimed exclusively by another
        // app, device in power-state limbo, coreaudiod stuck after a
        // recent input swap. After `timeoutSeconds` of no progress treat
        // the in-flight attempt as a timeout — different path from a
        // hard failure (config error, no device) because timeouts on
        // wired devices typically clear on a same-device retry.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self else { return }
            guard self.startInFlight, generation == self.startGeneration else { return }
            let err = NSError(
                domain: "Dictator",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(device.localizedName) didn't respond. Another app may be using it — try a different input in Settings."
                ]
            )
            self.handleStartTimeout(
                error: err,
                device: device,
                sameDeviceRetriesRemaining: sameDeviceRetriesRemaining,
                allowDefaultFallback: allowDefaultFallback,
                generation: generation,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    /// Main-actor completion handler for a successful off-main setup. If
    /// the generation no longer matches, the user released the hotkey
    /// while we were warming up — drop the session rather than firing
    /// `onReady`.
    private func adoptSession(
        session newSession: AVCaptureSession,
        forwarder: SampleBufferForwarder,
        generation: Int
    ) {
        guard generation == startGeneration else {
            stopSessionAsync(newSession)
            return
        }
        session = newSession
        sampleForwarder = forwarder
        installObservers(for: newSession)
        running = true
        startInFlight = false
        startSilentCaptureWatchdog()
        onReady?()
    }

    /// Called on hard configuration errors (no device, can't add input /
    /// output to the session). Skips the same-device retry path because
    /// these errors are repeatable — retrying the same device just hits
    /// the same wall.
    private func handleStartFailure(
        error: Error,
        allowDefaultFallback: Bool,
        generation: Int
    ) {
        guard generation == startGeneration else { return }
        if allowDefaultFallback {
            // Bump the generation so any still-pending detached task
            // becomes stale on completion. Retry against the system
            // default with a short watchdog; if that fails too, surface
            // the error.
            startGeneration &+= 1
            startSessionAsync(
                device: AVCaptureDevice.default(for: .audio),
                allowDefaultFallback: false,
                sameDeviceRetriesRemaining: 0,
                generation: startGeneration,
                timeoutSeconds: 3
            )
        } else {
            startInFlight = false
            onStartFailed?(error)
        }
    }

    /// Called when the warmup watchdog fires. Distinct from
    /// `handleStartFailure` because a wedged `startRunning()` on a wired
    /// device — the common case the user actually sees — almost always
    /// clears on a same-device retry; that's much closer to what the
    /// user wanted (their picked input) than the silent fallback to the
    /// system default that the old code did. We bump the generation
    /// before the retry so the original hung detached task's eventual
    /// completion gets discarded by `adoptSession`'s generation guard.
    private func handleStartTimeout(
        error: Error,
        device: AVCaptureDevice,
        sameDeviceRetriesRemaining: Int,
        allowDefaultFallback: Bool,
        generation: Int,
        timeoutSeconds: Double
    ) {
        guard generation == startGeneration else { return }
        if sameDeviceRetriesRemaining > 0 {
            startGeneration &+= 1
            startSessionAsync(
                device: device,
                allowDefaultFallback: allowDefaultFallback,
                sameDeviceRetriesRemaining: sameDeviceRetriesRemaining - 1,
                generation: startGeneration,
                timeoutSeconds: timeoutSeconds
            )
        } else if allowDefaultFallback {
            startGeneration &+= 1
            startSessionAsync(
                device: AVCaptureDevice.default(for: .audio),
                allowDefaultFallback: false,
                sameDeviceRetriesRemaining: 0,
                generation: startGeneration,
                timeoutSeconds: 3
            )
        } else {
            startInFlight = false
            onStartFailed?(error)
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
            // Extract Sendable values from the Notification before crossing
            // into MainActor.assumeIsolated — Notification itself isn't
            // Sendable so Swift 6 won't let us reference it from inside.
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "unknown error"
            MainActor.assumeIsolated {
                self?.handleUnexpectedStop("Audio capture failed: \(detail).")
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
                guard let self, let uniqueID else { return }
                guard self.running else { return }
                let inputDevices = (self.session?.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }) ?? []
                guard inputDevices.contains(where: { $0.uniqueID == uniqueID }) else { return }
                self.handleUnexpectedStop("\(localizedName) was disconnected.")
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUnexpectedStop("Audio capture was interrupted.")
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
            stopSessionAsync(s)
        }
        session = nil
        sampleForwarder = nil
    }

    /// `stopRunning()` can block briefly when tearing down a Bluetooth
    /// session (un-engaging HFP). Move it off-main so it doesn't beach-
    /// ball the UI during a stop. Capture the session by value into the
    /// detached task — once we've stopped tracking it on the main actor
    /// it's safe to let the task own it for the brief stop window.
    private nonisolated func stopSessionAsync(_ session: AVCaptureSession) {
        Task.detached { session.stopRunning() }
    }

    private func handleUnexpectedStop(_ message: String) {
        guard running else { return }
        teardownSession()
        running = false
        onUnexpectedStop?(message)
    }

    // MARK: - Silent-capture watchdog

    /// Belt-and-braces: AVCaptureSession.startRunning() can return having
    /// declared itself "running" without ever producing a sample buffer
    /// (we've seen this on USB devices that get stuck mid-init). Without
    /// this, the user gets a Recording state with a flat waveform and no
    /// transcript. After 1.5 s of running with no buffer delivered, treat
    /// it as a startup failure so the pipeline can leave the recording
    /// state cleanly.
    private func startSilentCaptureWatchdog() {
        silentCaptureTask?.cancel()
        silentCaptureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            guard self.running, self.lastBufferTime == nil else { return }
            self.handleUnexpectedStop("Mic isn't producing audio. Try a different input in Settings.")
        }
    }

    // MARK: - Sample buffer ingest

    private func appendSamples(mono: [Float], level: Float, sampleRate: Double) {
        // Drop samples that arrive after teardown — outputQueue callbacks
        // can race with stopRunning by a few milliseconds.
        guard running || startInFlight else { return }
        rawBuffer.append(contentsOf: mono)
        nativeSampleRate = sampleRate
        lastBufferTime = Date()
        onLevel?(level)
        onInterimSamples?(mono, sampleRate)
    }

    // MARK: - Static helpers (off-main, no actor isolation)

    private struct ProcessedBuffer: Sendable {
        let mono: [Float]
        let level: Float
        let sampleRate: Double
    }

    private nonisolated static func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> ProcessedBuffer? {
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
        // Defensive: the CMBlockBuffer should contain exactly
        // frameCount * channels floats. Bail rather than read garbage.
        guard totalFloats == frameCount * channels else { return nil }

        let floats = UnsafeRawPointer(dataPointer)
            .assumingMemoryBound(to: Float.self)
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
        // Map RMS onto [0, 1] via a square-root curve. Linear scaling (the
        // original `rms * 8`) collapses quieter mics — AirPods, distant USB,
        // anything with low OS-side gain — below the HUD waveform's 0.05
        // floor, so the bars looked frozen during normal speech. Sqrt
        // compresses the dynamic range so RMS ~0.005 (quiet) lifts visibly
        // off the floor without pinning RMS ~0.2 (loud) at the top.
        let level = min(1, max(0, sqrtf(rms) * 2.5))
        return ProcessedBuffer(mono: mono, level: level, sampleRate: sampleRate)
    }

    /// Resolve a preferred entry through to a live `AVCaptureDevice`. The
    /// "System default" sentinel — and any fall-through case — resolves to
    /// `AVCaptureDevice.default(for: .audio)`, which is whatever macOS
    /// currently has set as the system input. `AVCaptureDevice.uniqueID`
    /// matches CoreAudio's device UID for real hardware, so the look-up
    /// just works. Nonisolated and takes the preferred entry as a parameter
    /// (rather than reading `AudioDeviceManager.shared` itself) so the
    /// caller can do the cheap dict read on main and hand the heavy
    /// `AVCaptureDevice(uniqueID:)` lookup off to a background task.
    private nonisolated static func resolveCaptureDevice(preferred: AudioDevice?) -> AVCaptureDevice? {
        guard let preferred else {
            return AVCaptureDevice.default(for: .audio)
        }
        if preferred.isSystemDefault {
            return AVCaptureDevice.default(for: .audio)
        }
        return AVCaptureDevice(uniqueID: preferred.uid)
            ?? AVCaptureDevice.default(for: .audio)
    }

    /// Converts a mono Float32 stream at one sample rate to another via
    /// AVAudioConverter. Used at `stop()` time to land WhisperKit's
    /// expected 16 kHz input.
    private nonisolated static func resampleToTarget(
        monoSamples: [Float],
        fromSampleRate: Double,
        toSampleRate: Double
    ) -> [Float]? {
        guard !monoSamples.isEmpty else { return [] }
        if abs(fromSampleRate - toSampleRate) < 1 { return monoSamples }

        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromSampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(monoSamples.count))
        else { return nil }

        inputBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, monoSamples.count * MemoryLayout<Float>.size)
            }
        }

        let ratio = toSampleRate / fromSampleRate
        let outCap = AVAudioFrameCount(Double(monoSamples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return nil }

        var error: NSError?
        let supplied = MutableFlag()
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied.value {
                status.pointee = .endOfStream
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return inputBuffer
        }
        if error != nil { return nil }
        guard let outData = outBuffer.floatChannelData?[0] else { return nil }
        let outCount = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outData, count: outCount))
    }
}
