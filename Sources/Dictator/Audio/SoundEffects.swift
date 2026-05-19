import Foundation
@preconcurrency import AVFoundation

@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var started = false
    private var configChangeObserver: NSObjectProtocol?

    private let armBuffer: AVAudioPCMBuffer
    private let startBuffer: AVAudioPCMBuffer
    private let stopBuffer: AVAudioPCMBuffer
    private let doneBuffer: AVAudioPCMBuffer

    private init() {
        // Mono player straight into mainMixerNode. mainMixer has a built-in
        // sample-rate converter, so it tolerates the hardware output rate
        // shifting (48k speaker → 24k AirPods → 192k external interface)
        // without any reconfiguration on our side. Earlier we routed through
        // AVAudioUnitReverb for a small-room tail, but the AU graph then
        // required every node's sample rate to agree, and a mid-session
        // hardware switch tripped kAudioUnitErr_FormatNotSupported (-10868).
        // The bell-partial synthesis below carries the polish without it.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        format = fmt
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        // Real bells have inharmonic partials (non-integer overtones) and each
        // partial decays at its own rate — the higher you go, the faster it
        // fades. That's the single biggest difference between "synth tone"
        // and "real bell". `bellPartials` encodes that physical reality.
        //
        // The arm cue uses `woodPartials` instead — fewer and lower partials,
        // softer attack — so it reads as a different *category* of event
        // (preparing) rather than just a quieter version of the bells (ready
        // / done).
        //
        // Pitch design: rising F#4 → D5 from arm → start reads as
        // "preparing → go". Stop drops to A4 (a 4th below start) for clear
        // "finished capturing" closure. Done climbs to A5 — bright but no
        // longer piercing — for "transcription delivered".
        armBuffer   = Self.makeTone(format: fmt, frequency: 370, partials: Self.woodPartials,  attackSeconds: 0.025, durationMS: 180, amplitude: 0.12)  // F#4, woody
        startBuffer = Self.makeTone(format: fmt, frequency: 587, partials: Self.chimePartials, attackSeconds: 0.020, durationMS: 400, amplitude: 0.16)  // D5
        stopBuffer  = Self.makeTone(format: fmt, frequency: 440, partials: Self.chimePartials, attackSeconds: 0.018, durationMS: 400, amplitude: 0.16)  // A4
        doneBuffer  = Self.makeTone(format: fmt, frequency: 880, partials: Self.chimePartials, attackSeconds: 0.014, durationMS: 320, amplitude: 0.11)  // A5, quieter

        // mainMixer routes our 44.1 kHz mono through to whatever output rate
        // the active hardware uses. When the user swaps speakers / headphones
        // / external interface, AVAudioEngine stops itself and fires this
        // notification (per Apple's spec). Without handling it, our `started`
        // flag goes stale and every subsequent play() silently no-ops.
        // AudioRecorder and InputLevelMonitor follow the same pattern.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
    }

    func playArm()   { play(armBuffer)   }
    func playStart() { play(startBuffer) }
    func playStop()  { play(stopBuffer)  }
    func playDone()  { play(doneBuffer)  }

    private func play(_ buffer: AVAudioPCMBuffer) {
        startEngineIfNeeded()
        // If the engine wouldn't come up at all (no output device available,
        // for instance) scheduling a buffer and asking the player to play
        // throws on the audio thread. Skip silently — the user just doesn't
        // hear this cue; the rest of the pipeline carries on.
        guard started else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func startEngineIfNeeded() {
        guard !started else { return }
        engine.prepare()
        do {
            try engine.start()
            started = true
        } catch {
            // Recovery: rebuild the player→mixer connection in case the
            // graph was invalidated by hardware churn we didn't catch via
            // the configuration-change notification, then retry once.
            connectGraph()
            do {
                try engine.start()
                started = true
            } catch {
                started = false
            }
        }
    }

    /// (Re)builds the `player → mainMixerNode` connection. Idempotent —
    /// disconnects any existing input on the mixer first. Called from init
    /// and from the configuration-change handler / recovery path.
    private func connectGraph() {
        if player.engine == nil { engine.attach(player) }
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private func handleConfigurationChange() {
        // AVAudioEngine stops itself before dispatching the notification.
        // Drop the started flag so the next play() restarts the engine, and
        // rebuild the connection because the mixer's downstream format may
        // have changed (its SRC will sort the rest).
        started = false
        if player.isPlaying { player.stop() }
        connectGraph()
    }

    // MARK: - Synthesis

    private struct Partial {
        let ratio: Float        // multiple of the fundamental (non-integer is fine)
        let gain: Float         // relative amplitude at t=0
        let decay: Float        // higher = faster fall-off
    }

    /// Warm chime partials — purely harmonic (no inharmonic strike tone),
    /// with a quiet sub-octave for body. The sub-octave is the warmth lever:
    /// it adds the lower-frequency resonance the ear reads as "real wooden
    /// instrument" rather than "synthesised tone". The 3× partial (perfect
    /// 12th) replaces a 4× double-octave because human-vocal/orchestral
    /// instruments emphasise 3×, so the ear hears it as natural sparkle
    /// rather than synth-bright. `decay` is normalised to buffer duration,
    /// so end-of-buffer amplitude is exp(-decay) — keep it ≥ 4 so residual
    /// is below 2% before the tail-fade cleans up.
    private static let chimePartials: [Partial] = [
        Partial(ratio: 0.500, gain: 0.18, decay: 4.0),   // sub-octave body
        Partial(ratio: 1.000, gain: 1.00, decay: 4.5),   // fundamental
        Partial(ratio: 2.000, gain: 0.22, decay: 6.0),   // octave warmth
        Partial(ratio: 3.000, gain: 0.07, decay: 8.5),   // perfect 12th sparkle
    ]

    /// Woody / muted partial structure. Fundamental + light sub-octave for
    /// body + a touch of octave. No inharmonic shimmer, no high sparkle,
    /// faster overall decay. Feels like a soft mallet on a damped wooden
    /// block — distinct enough from the chimes to read as a different
    /// category of event.
    private static let woodPartials: [Partial] = [
        Partial(ratio: 0.500, gain: 0.10, decay: 4.5),
        Partial(ratio: 1.000, gain: 1.00, decay: 5.0),
        Partial(ratio: 2.000, gain: 0.15, decay: 6.5),
    ]

    private static func makeTone(format: AVAudioFormat,
                                 frequency: Float,
                                 partials: [Partial],
                                 attackSeconds: Float,
                                 durationMS: Int,
                                 amplitude: Float) -> AVAudioPCMBuffer {
        let sampleRate = Float(format.sampleRate)
        let frameCount = AVAudioFrameCount(sampleRate * Float(durationMS) / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return buffer }
        let channelCount = Int(format.channelCount)

        let durationSeconds = Float(durationMS) / 1000
        let attackFraction = attackSeconds / durationSeconds
        // Final 25 ms gets a cosine fade-out to zero so however the partials
        // are sitting at end-of-buffer they don't produce a hard cut. Cheap
        // hygiene that lets us pick any decay value without an audible click.
        let tailFadeSeconds: Float = 0.025
        let tailFadeStart = max(0, durationSeconds - tailFadeSeconds)

        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let normalized = t / durationSeconds // 0…1

            // Raised-cosine attack to eliminate the onset click of a hard
            // ramp; held flat at 1.0 after the attack so the per-partial
            // exponential decays handle the rest.
            let attackEnv: Float
            if t < attackSeconds {
                attackEnv = 0.5 - 0.5 * cosf(.pi * t / attackSeconds)
            } else {
                attackEnv = 1.0
            }
            let tailEnv: Float
            if t >= tailFadeStart {
                let into = (t - tailFadeStart) / tailFadeSeconds
                tailEnv = 0.5 + 0.5 * cosf(.pi * min(into, 1))
            } else {
                tailEnv = 1.0
            }
            let decayPhase = max(0, normalized - attackFraction)

            var sample: Float = 0
            for p in partials {
                let env = expf(-p.decay * decayPhase)
                sample += p.gain * env * sinf(2 * .pi * frequency * p.ratio * t)
            }

            let s = sample * attackEnv * tailEnv * amplitude
            for c in 0..<channelCount { channels[c][i] = s }
        }
        return buffer
    }
}
