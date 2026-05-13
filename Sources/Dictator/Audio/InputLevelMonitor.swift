import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreAudio

/// Lightweight AVAudioEngine wrapper whose only job is to publish a live
/// 0...1 RMS level while the Settings → Input pane is on screen. Independent
/// of `AudioRecorder` — runs its own engine on its own tap so the user can
/// see whether the mic is picking anything up *without* triggering a real
/// dictation.
///
/// Failures are deliberately silent. Settings is not the right place to
/// surface "audio engine couldn't start" — if the engine fails to come up
/// (mic permission denied, no usable input device, the OS refusing to
/// double-listen on a device), the meter just stays at zero. The
/// permission-state hint in the UI covers the most common reason.
@MainActor
@Observable
final class InputLevelMonitor {
    /// Latest 0...1 RMS level. Mutated from the audio thread via a hop to
    /// the main actor (so SwiftUI sees coherent updates).
    private(set) var level: Float = 0
    /// True once an engine is running and producing buffer callbacks.
    /// Drives the "Live" vs "Mic access required" copy in the UI.
    private(set) var isActive: Bool = false
    /// True when mic permission is in a state where we can't tap input
    /// (`.denied`, `.restricted`). The Input pane uses this to point the
    /// user at System Settings → Privacy. We deliberately do *not* trigger
    /// the OS prompt from here — that belongs on the General pane's
    /// dedicated Request button so it has clear intent attached.
    private(set) var permissionDenied: Bool = false

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var configChangeObserver: NSObjectProtocol?
    /// Timestamp of the most recent tap callback's hop to the main actor.
    /// The watchdog uses this to detect the case where macOS has quietly
    /// suspended buffer delivery to a long-running tap-only engine — the
    /// callbacks just stop arriving, with no configuration-change event.
    @ObservationIgnored private var lastBufferTime: Date?
    /// Polls `lastBufferTime` every 500 ms. If the engine claims to be
    /// running but no buffer has arrived recently, we tear down and
    /// re-arm. Survives `configureAndStart` restarts — owned by `start`
    /// and `stop`.
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    /// Spin up the meter. No-op if already running. Walks the mic-permission
    /// state machine first so we don't pop the OS prompt from a passive
    /// settings view.
    func start() {
        guard !isActive else { return }
        switch MicPermission.status() {
        case .denied, .restricted:
            permissionDenied = true
            return
        case .notDetermined:
            // Not our place to ask — the General pane has the dedicated
            // Request button. Leave the meter inert until the user grants.
            return
        case .authorized:
            permissionDenied = false
        @unknown default:
            return
        }

        do {
            try configureAndStart(deviceOverride: AudioDeviceManager.shared.activeInputDeviceID())
        } catch {
            // Mirror AudioRecorder's recovery: a -10868 (format-mismatch)
            // failure on a device override often clears when we retry
            // against the system default.
            engine = AVAudioEngine()
            try? configureAndStart(deviceOverride: nil)
        }

        // Watchdog only spins up after the first successful start — no
        // point polling for buffers when the engine never came up at all.
        if isActive {
            startWatchdog()
        }
    }

    /// Tear the engine down. Safe to call multiple times.
    func stop() {
        guard isActive else { return }
        watchdogTask?.cancel()
        watchdogTask = nil
        teardown()
        isActive = false
        level = 0
        lastBufferTime = nil
    }

    /// Belt-and-braces detector for the macOS-pauses-our-tap bug. Most of
    /// the time the silent-output sink below keeps the engine "active" in
    /// the HAL's eyes and the tap fires reliably; this watchdog covers any
    /// remaining edge case (and means the longest hang the user can ever
    /// see is bounded by the 500 ms poll interval + restart latency).
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard self.isActive, let last = self.lastBufferTime else { continue }
                // 600 ms is comfortably longer than any legitimate buffer
                // interval (≈85 ms at 48 kHz, ≈256 ms even on a 16 kHz
                // device with our 4096-sample buffer) but short enough that
                // a hang reads as a momentary glitch, not a freeze.
                if Date().timeIntervalSince(last) > 0.6 {
                    self.teardown()
                    self.isActive = false
                    try? self.configureAndStart(deviceOverride: nil)
                }
            }
        }
    }

    private func configureAndStart(deviceOverride: AudioDeviceID?) throws {
        // Fresh engine each call so the AUHAL has no stale device/format
        // state — same reason AudioRecorder does it.
        engine = AVAudioEngine()
        if let id = deviceOverride {
            try? Self.setInputDevice(id, on: engine)
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // @Sendable + `format: nil` are load-bearing (see AudioRecorder for
        // the full story). The closure runs on the realtime audio thread.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] pcm, _ in
            let rms = Self.computeRMS(pcm: pcm)
            Task { @MainActor [weak self, rms] in
                self?.level = rms
                self?.lastBufferTime = Date()
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)

        // Force a complete graph so macOS doesn't decide our tap-only
        // engine is idle and silently suspend buffer delivery to the tap.
        // mainMixerNode auto-connects to the output node; we mute it so
        // nothing audible reaches the speakers. CPU cost is negligible at
        // volume 0 and a 4096-sample buffer.
        engine.connect(input, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }

        engine.prepare()
        try engine.start()
        isActive = true
        // Bootstrap so the watchdog doesn't false-fire before the first
        // real buffer lands (engine.start → first tap can take ~85 ms).
        lastBufferTime = Date()
    }

    private func handleConfigurationChange() {
        guard isActive else { return }
        teardown()
        isActive = false
        // Re-arm on whatever input is active now. Silent on failure — the
        // meter just stops moving, which is exactly the signal the user
        // needs ("my new mic isn't picking anything up").
        try? configureAndStart(deviceOverride: nil)
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        engine.stop()
    }

    private static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't set input device (OSStatus \(status))"]
            )
        }
    }

    /// Mono-mix + RMS, clamped to 0...1 with the same x8 scaling AudioRecorder
    /// uses so the meter visually matches the in-recording HUD waveform.
    /// `nonisolated static` so it can run on the realtime audio thread.
    private nonisolated static func computeRMS(pcm: AVAudioPCMBuffer) -> Float {
        guard let channelData = pcm.floatChannelData else { return 0 }
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0 else { return 0 }
        let channels = Int(pcm.format.channelCount)

        // Explicit `-> Void` on each closure so the compiler doesn't oscillate
        // between "discardable result" and "result unused" warnings — both
        // memcpy and the vDSP routines return values we genuinely don't need.
        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                memcpy(dst.baseAddress!, channelData[0], frameCount * MemoryLayout<Float>.size)
            }
        } else {
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                let base = dst.baseAddress!
                for i in 0..<frameCount { base[i] = 0 }
                for ch in 0..<channels {
                    vDSP_vadd(base, 1, channelData[ch], 1, base, 1, vDSP_Length(frameCount))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frameCount))
            }
        }
        var rms: Float = 0
        mono.withUnsafeBufferPointer { ptr -> Void in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(frameCount))
        }
        return min(1, max(0, rms * 8))
    }
}
