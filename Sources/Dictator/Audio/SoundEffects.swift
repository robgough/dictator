import Foundation
@preconcurrency import AVFoundation

@MainActor
final class SoundEffects {
    static let shared = SoundEffects()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var started = false

    private let startBuffer: AVAudioPCMBuffer
    private let stopBuffer: AVAudioPCMBuffer
    private let doneBuffer: AVAudioPCMBuffer

    private init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        format = fmt
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        // Two-tone bell-style chimes. Bell envelope = fast attack + exponential decay,
        // so each one decays naturally rather than hard-cutting. Adding a single
        // harmonic gives them a touch of warmth without sounding synthetic.
        startBuffer = Self.makeBell(format: fmt, frequency: 880,  harmonicMix: 0.30, durationMS: 180, amplitude: 0.22)  // A5
        stopBuffer  = Self.makeBell(format: fmt, frequency: 659,  harmonicMix: 0.30, durationMS: 180, amplitude: 0.22)  // E5
        doneBuffer  = Self.makeBell(format: fmt, frequency: 1318, harmonicMix: 0.18, durationMS: 140, amplitude: 0.14)  // E6, quieter
    }

    func playStart() { play(startBuffer) }
    func playStop()  { play(stopBuffer)  }
    func playDone()  { play(doneBuffer)  }

    private func play(_ buffer: AVAudioPCMBuffer) {
        startEngineIfNeeded()
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
            started = false
        }
    }

    // MARK: - Synthesis

    private static func makeBell(format: AVAudioFormat,
                                 frequency: Float,
                                 harmonicMix: Float,
                                 durationMS: Int,
                                 amplitude: Float) -> AVAudioPCMBuffer {
        let sampleRate = Float(format.sampleRate)
        let frameCount = AVAudioFrameCount(sampleRate * Float(durationMS) / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let samples = buffer.floatChannelData?[0] else { return buffer }

        let attackSeconds: Float = 0.004        // 4 ms attack
        let decayConstant: Float = 4.5          // higher = faster fall-off
        let durationSeconds = Float(durationMS) / 1000

        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let normalized = t / durationSeconds // 0…1

            let envelope: Float
            if t < attackSeconds {
                envelope = t / attackSeconds
            } else {
                envelope = expf(-decayConstant * (normalized - attackSeconds / durationSeconds))
            }

            let fundamental = sinf(2 * .pi * frequency * t)
            let harmonic    = sinf(2 * .pi * frequency * 2 * t)
            let mix = fundamental + harmonic * harmonicMix
            samples[i] = mix * envelope * amplitude
        }
        return buffer
    }
}
