import Foundation

/// The user's choice of cue set — Settings → General → Sounds. Lives here
/// rather than with the other settings enums because `SoundSynth` must stay
/// Foundation-only (the `scratch/sound-preview` renderer compiles this one
/// file standalone).
enum SoundTheme: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case classic
    case glass
    case soft
    case wood
    case minimal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .glass: return "Glass"
        case .soft: return "Soft"
        case .wood: return "Wood"
        case .minimal: return "Minimal"
        }
    }

    var detail: String {
        switch self {
        case .classic: return "The original chimes."
        case .glass: return "Bright struck glass with a little air."
        case .soft: return "Warm, gentle glass."
        case .wood: return "A mallet on a marimba bar."
        case .minimal: return "Quiet ticks, barely there."
        }
    }
}

/// Offline synthesis for the four UI cues — arm, start, stop, done — in each
/// of the `SoundTheme`s. Pure maths, Foundation only: `SoundEffects` renders
/// these once into CAF files and replays them as system sounds, and
/// `scratch/sound-preview` compiles this same file into a little renderer
/// for auditioning WAVs without building the app.
///
/// Every cue is built from the same parts: struck notes (a set of decaying
/// sine partials, an attack, an optional noise tap at the onset), a low-pass
/// to take the edge off, and a short stereo reverb. A theme is a palette of
/// partials plus a recipe per cue — pitches, timing, length, how much air.
/// Each cue is a small motif (a rising interval for start, the same interval
/// falling for stop, a dyad for done) so the four read as designed events
/// rather than four pitches of the same beep.
enum SoundSynth {
    enum Cue: String, CaseIterable {
        case arm, start, stop, done
    }

    static let sampleRate: Float = 44_100

    struct Partial {
        /// Multiple of the note's fundamental. Non-integer = inharmonic.
        let ratio: Float
        /// Relative amplitude at the moment of the strike.
        let gain: Float
        /// Time constant in seconds: amplitude falls to 1/e after this long.
        let decay: Float
    }

    /// One struck note inside a cue.
    struct Note {
        let frequency: Float
        let startSeconds: Float
        let gain: Float
        let partials: [Partial]
        /// Raised-cosine attack length.
        let attackSeconds: Float
        /// Level of the noise "tap" at the onset, relative to `gain`. 0 = none.
        let strike: Float
    }

    struct Recipe {
        let notes: [Note]
        let durationSeconds: Float
        /// Normalise the finished mix to this peak (linear, 1.0 = full scale).
        let peak: Float
        /// Reverb wet level, 0…1. 0 = dry.
        let reverb: Float
        /// Reverb tail darkening, 0…1 — higher = the tail loses its highs faster.
        let reverbDamping: Float
        /// Left/right detune in cents (opposite signs per channel). With the
        /// partial detune this decorrelates the channels — the width.
        let widthCents: Float
        /// One-pole low-pass on the finished note, before the reverb. The
        /// softness lever. 0 = bypass.
        let toneCutoffHz: Float
    }

    // MARK: - Palettes

    /// Classic chime (the original cues, pre-September 2026): purely
    /// harmonic with a quiet sub-octave for body. Time constants are the old
    /// buffer-normalised decays converted for a 0.4 s note.
    static let classicChime: [Partial] = [
        Partial(ratio: 0.500, gain: 0.18, decay: 0.100),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.089),
        Partial(ratio: 2.000, gain: 0.22, decay: 0.067),
        Partial(ratio: 3.000, gain: 0.07, decay: 0.047),
    ]
    /// Same, for the original 0.32 s done cue.
    static let classicChimeShort: [Partial] = [
        Partial(ratio: 0.500, gain: 0.18, decay: 0.080),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.071),
        Partial(ratio: 2.000, gain: 0.22, decay: 0.053),
        Partial(ratio: 3.000, gain: 0.07, decay: 0.038),
    ]
    /// The original woody arm tap.
    static let classicWood: [Partial] = [
        Partial(ratio: 0.500, gain: 0.10, decay: 0.040),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.036),
        Partial(ratio: 2.000, gain: 0.15, decay: 0.028),
    ]

    /// Bright glass: detuned twins on the low partials for shimmer and
    /// inharmonic upper modes (4.16×, 5.43×, 6.79× are roughly the mode
    /// ratios of a struck glass plate) that ring out quickly.
    static let glassBright: [Partial] = [
        Partial(ratio: 0.500, gain: 0.08, decay: 0.45),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.55),
        Partial(ratio: 1.004, gain: 0.45, decay: 0.50),
        Partial(ratio: 2.000, gain: 0.34, decay: 0.32),
        Partial(ratio: 2.007, gain: 0.16, decay: 0.28),
        Partial(ratio: 3.010, gain: 0.20, decay: 0.20),
        Partial(ratio: 4.160, gain: 0.09, decay: 0.14),
        Partial(ratio: 5.430, gain: 0.045, decay: 0.09),
        Partial(ratio: 6.790, gain: 0.02, decay: 0.06),
    ]
    static let glassBrightTap: [Partial] = [
        Partial(ratio: 1.000, gain: 1.00, decay: 0.085),
        Partial(ratio: 1.005, gain: 0.35, decay: 0.070),
        Partial(ratio: 2.000, gain: 0.25, decay: 0.050),
        Partial(ratio: 3.010, gain: 0.10, decay: 0.030),
        Partial(ratio: 4.160, gain: 0.05, decay: 0.020),
    ]

    /// Soft glass: a warm fundamental with a quiet detuned twin (a slow,
    /// subtle beat), a little octave, and only a whisper of the glass modes.
    /// Short decays — these breathe rather than ring.
    static let glassSoft: [Partial] = [
        Partial(ratio: 0.500, gain: 0.12, decay: 0.30),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.32),
        Partial(ratio: 1.003, gain: 0.30, decay: 0.30),
        Partial(ratio: 2.000, gain: 0.18, decay: 0.18),
        Partial(ratio: 2.005, gain: 0.08, decay: 0.16),
        Partial(ratio: 3.010, gain: 0.06, decay: 0.10),
        Partial(ratio: 4.160, gain: 0.02, decay: 0.06),
        Partial(ratio: 5.430, gain: 0.008, decay: 0.04),
    ]
    static let glassSoftTap: [Partial] = [
        Partial(ratio: 1.000, gain: 1.00, decay: 0.075),
        Partial(ratio: 1.005, gain: 0.25, decay: 0.060),
        Partial(ratio: 2.000, gain: 0.12, decay: 0.040),
        Partial(ratio: 3.010, gain: 0.03, decay: 0.025),
    ]

    /// Marimba: a strong fundamental, the bar's characteristic 4× overtone
    /// (tuned two octaves up), a faint 9.2× mode, and a short decay.
    static let marimba: [Partial] = [
        Partial(ratio: 0.500, gain: 0.05, decay: 0.20),
        Partial(ratio: 1.000, gain: 1.00, decay: 0.22),
        Partial(ratio: 4.000, gain: 0.30, decay: 0.08),
        Partial(ratio: 9.200, gain: 0.06, decay: 0.03),
    ]
    static let marimbaTap: [Partial] = [
        Partial(ratio: 1.000, gain: 1.00, decay: 0.050),
        Partial(ratio: 4.000, gain: 0.20, decay: 0.030),
    ]

    /// Tick: mostly the noise tap, with a very short tone to give it a pitch.
    static let tick: [Partial] = [
        Partial(ratio: 1.000, gain: 1.00, decay: 0.018),
        Partial(ratio: 2.000, gain: 0.30, decay: 0.010),
    ]

    // MARK: - Recipes

    static func recipe(for cue: Cue, theme: SoundTheme) -> Recipe {
        switch theme {
        case .classic: return classic(cue)
        case .glass: return glass(cue)
        case .soft: return soft(cue)
        case .wood: return wood(cue)
        case .minimal: return minimal(cue)
        }
    }

    /// The pre-September-2026 cues, re-expressed in this engine: mono, dry,
    /// no tap, no low-pass. F♯4 wood tap, D5 / A4 / A5 chimes.
    private static func classic(_ cue: Cue) -> Recipe {
        switch cue {
        case .arm:
            return Recipe(notes: [Note(frequency: 370, startSeconds: 0, gain: 1, partials: classicWood, attackSeconds: 0.025, strike: 0)],
                          durationSeconds: 0.18, peak: 0.13, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 0)
        case .start:
            return Recipe(notes: [Note(frequency: 587, startSeconds: 0, gain: 1, partials: classicChime, attackSeconds: 0.020, strike: 0)],
                          durationSeconds: 0.40, peak: 0.18, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 0)
        case .stop:
            return Recipe(notes: [Note(frequency: 440, startSeconds: 0, gain: 1, partials: classicChime, attackSeconds: 0.018, strike: 0)],
                          durationSeconds: 0.40, peak: 0.18, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 0)
        case .done:
            return Recipe(notes: [Note(frequency: 880, startSeconds: 0, gain: 1, partials: classicChimeShort, attackSeconds: 0.014, strike: 0)],
                          durationSeconds: 0.32, peak: 0.125, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 0)
        }
    }

    /// Bright glass: a clear tap, long shimmer, open reverb. Rising fifth
    /// for start, falling fourth for stop, A5 + C♯6 for done.
    private static func glass(_ cue: Cue) -> Recipe {
        switch cue {
        case .arm:
            return Recipe(notes: [Note(frequency: 784, startSeconds: 0, gain: 1, partials: glassBrightTap, attackSeconds: 0.003, strike: 0.30)],
                          durationSeconds: 0.18, peak: 0.09, reverb: 0.10, reverbDamping: 0.30, widthCents: 2, toneCutoffHz: 0)
        case .start:
            return Recipe(notes: [
                Note(frequency: 587, startSeconds: 0.000, gain: 1.00, partials: glassBright, attackSeconds: 0.004, strike: 0.22),
                Note(frequency: 880, startSeconds: 0.085, gain: 0.85, partials: glassBright, attackSeconds: 0.004, strike: 0.18),
            ], durationSeconds: 0.55, peak: 0.16, reverb: 0.22, reverbDamping: 0.30, widthCents: 3, toneCutoffHz: 0)
        case .stop:
            return Recipe(notes: [
                Note(frequency: 659, startSeconds: 0.000, gain: 1.00, partials: glassBright, attackSeconds: 0.004, strike: 0.22),
                Note(frequency: 440, startSeconds: 0.085, gain: 0.90, partials: glassBright, attackSeconds: 0.004, strike: 0.16),
            ], durationSeconds: 0.55, peak: 0.16, reverb: 0.20, reverbDamping: 0.30, widthCents: 3, toneCutoffHz: 0)
        case .done:
            return Recipe(notes: [
                Note(frequency: 880, startSeconds: 0.000, gain: 1.00, partials: glassBright, attackSeconds: 0.003, strike: 0.20),
                Note(frequency: 1109, startSeconds: 0.035, gain: 0.55, partials: glassBright, attackSeconds: 0.003, strike: 0.10),
            ], durationSeconds: 0.65, peak: 0.12, reverb: 0.28, reverbDamping: 0.30, widthCents: 3, toneCutoffHz: 0)
        }
    }

    /// Soft glass: barely-there tap, slow attack, low-passed, dark tail.
    /// Rising fourth A4 → D5 for start, the same falling for stop, E5 + G♯5
    /// for done, a D5 tap for arm (the note start lands on).
    private static func soft(_ cue: Cue) -> Recipe {
        switch cue {
        case .arm:
            return Recipe(notes: [Note(frequency: 587, startSeconds: 0, gain: 1, partials: glassSoftTap, attackSeconds: 0.006, strike: 0.12)],
                          durationSeconds: 0.16, peak: 0.08, reverb: 0.12, reverbDamping: 0.55, widthCents: 2, toneCutoffHz: 4000)
        case .start:
            return Recipe(notes: [
                Note(frequency: 440, startSeconds: 0.000, gain: 1.00, partials: glassSoft, attackSeconds: 0.014, strike: 0.05),
                Note(frequency: 587, startSeconds: 0.090, gain: 0.90, partials: glassSoft, attackSeconds: 0.014, strike: 0.04),
            ], durationSeconds: 0.42, peak: 0.13, reverb: 0.26, reverbDamping: 0.55, widthCents: 3, toneCutoffHz: 3200)
        case .stop:
            return Recipe(notes: [
                Note(frequency: 587, startSeconds: 0.000, gain: 1.00, partials: glassSoft, attackSeconds: 0.014, strike: 0.05),
                Note(frequency: 440, startSeconds: 0.090, gain: 0.90, partials: glassSoft, attackSeconds: 0.014, strike: 0.04),
            ], durationSeconds: 0.42, peak: 0.13, reverb: 0.24, reverbDamping: 0.55, widthCents: 3, toneCutoffHz: 3200)
        case .done:
            return Recipe(notes: [
                Note(frequency: 659, startSeconds: 0.000, gain: 1.00, partials: glassSoft, attackSeconds: 0.016, strike: 0.04),
                Note(frequency: 831, startSeconds: 0.040, gain: 0.55, partials: glassSoft, attackSeconds: 0.016, strike: 0.02),
            ], durationSeconds: 0.55, peak: 0.11, reverb: 0.30, reverbDamping: 0.55, widthCents: 3, toneCutoffHz: 3200)
        }
    }

    /// Marimba, an octave down from the glass sets: A3 → D4 for start, the
    /// reverse for stop, E4 + G♯4 for done, a D4 tap for arm.
    private static func wood(_ cue: Cue) -> Recipe {
        switch cue {
        case .arm:
            return Recipe(notes: [Note(frequency: 294, startSeconds: 0, gain: 1, partials: marimbaTap, attackSeconds: 0.005, strike: 0.10)],
                          durationSeconds: 0.14, peak: 0.12, reverb: 0.12, reverbDamping: 0.50, widthCents: 2, toneCutoffHz: 2500)
        case .start:
            return Recipe(notes: [
                Note(frequency: 220, startSeconds: 0.000, gain: 1.00, partials: marimba, attackSeconds: 0.006, strike: 0.10),
                Note(frequency: 294, startSeconds: 0.090, gain: 0.95, partials: marimba, attackSeconds: 0.006, strike: 0.08),
            ], durationSeconds: 0.38, peak: 0.17, reverb: 0.20, reverbDamping: 0.50, widthCents: 3, toneCutoffHz: 2500)
        case .stop:
            return Recipe(notes: [
                Note(frequency: 294, startSeconds: 0.000, gain: 1.00, partials: marimba, attackSeconds: 0.006, strike: 0.10),
                Note(frequency: 220, startSeconds: 0.090, gain: 0.95, partials: marimba, attackSeconds: 0.006, strike: 0.08),
            ], durationSeconds: 0.38, peak: 0.17, reverb: 0.20, reverbDamping: 0.50, widthCents: 3, toneCutoffHz: 2500)
        case .done:
            return Recipe(notes: [
                Note(frequency: 330, startSeconds: 0.000, gain: 1.00, partials: marimba, attackSeconds: 0.006, strike: 0.10),
                Note(frequency: 415, startSeconds: 0.040, gain: 0.60, partials: marimba, attackSeconds: 0.006, strike: 0.05),
            ], durationSeconds: 0.50, peak: 0.15, reverb: 0.24, reverbDamping: 0.50, widthCents: 3, toneCutoffHz: 2500)
        }
    }

    /// Ticks: dry, tiny, quiet. One for arm, a rising pair for start, a
    /// falling pair for stop, a double for done.
    private static func minimal(_ cue: Cue) -> Recipe {
        switch cue {
        case .arm:
            return Recipe(notes: [Note(frequency: 1200, startSeconds: 0, gain: 1, partials: tick, attackSeconds: 0.001, strike: 0.7)],
                          durationSeconds: 0.06, peak: 0.09, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 7000)
        case .start:
            return Recipe(notes: [
                Note(frequency: 900, startSeconds: 0.00, gain: 1.0, partials: tick, attackSeconds: 0.001, strike: 0.7),
                Note(frequency: 1200, startSeconds: 0.07, gain: 1.0, partials: tick, attackSeconds: 0.001, strike: 0.7),
            ], durationSeconds: 0.14, peak: 0.10, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 7000)
        case .stop:
            return Recipe(notes: [
                Note(frequency: 1200, startSeconds: 0.00, gain: 1.0, partials: tick, attackSeconds: 0.001, strike: 0.7),
                Note(frequency: 900, startSeconds: 0.07, gain: 1.0, partials: tick, attackSeconds: 0.001, strike: 0.7),
            ], durationSeconds: 0.14, peak: 0.10, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 7000)
        case .done:
            return Recipe(notes: [
                Note(frequency: 1500, startSeconds: 0.00, gain: 1.0, partials: tick, attackSeconds: 0.001, strike: 0.7),
                Note(frequency: 1500, startSeconds: 0.09, gain: 0.9, partials: tick, attackSeconds: 0.001, strike: 0.7),
            ], durationSeconds: 0.16, peak: 0.09, reverb: 0, reverbDamping: 0, widthCents: 0, toneCutoffHz: 7000)
        }
    }

    // MARK: - Rendering

    /// Renders a cue as two channels of Float32 samples at `sampleRate`,
    /// normalised to the recipe's peak, with a cosine fade over the last
    /// 40 ms so a reverb tail can't end on a click. Deterministic: the tap
    /// noise comes from a fixed-seed generator, so the same recipe always
    /// renders the same bytes.
    static func render(_ cue: Cue, theme: SoundTheme) -> [[Float]] {
        let recipe = recipe(for: cue, theme: theme)
        let sr = sampleRate
        let n = Int(sr * recipe.durationSeconds)
        var channels = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        var rng = LCG(seed: 0x5EED_0000 + UInt64(cue.rawValue.utf8.reduce(0) { $0 &+ UInt64($1) }))

        for note in recipe.notes {
            let startIndex = Int(note.startSeconds * sr)
            guard startIndex < n else { continue }

            for ch in 0..<2 {
                let cents = ch == 0 ? -recipe.widthCents : recipe.widthCents
                let f = note.frequency * powf(2, cents / 1200)
                for i in startIndex..<n {
                    let t = Float(i - startIndex) / sr
                    let attack: Float = t < note.attackSeconds
                        ? 0.5 - 0.5 * cosf(.pi * t / note.attackSeconds)
                        : 1
                    var s: Float = 0
                    for p in note.partials {
                        s += p.gain * expf(-t / p.decay) * sinf(2 * .pi * f * p.ratio * t)
                    }
                    channels[ch][i] += s * attack * note.gain
                }
            }

            // The tap: 20 ms of high-passed noise with a ~3.5 ms decay, the
            // same in both channels so the transient sits dead centre, with
            // a 0.4 ms raised-cosine ramp on the front so the file never
            // steps straight out of digital silence.
            guard note.strike > 0 else { continue }
            let strikeLength = min(Int(0.020 * sr), n - startIndex)
            let strikeRamp = max(1, Int(0.0004 * sr))
            var previousInput: Float = 0
            var previousOutput: Float = 0
            for k in 0..<strikeLength {
                let x = rng.nextUnit() * 2 - 1
                let hp = 0.92 * (previousOutput + x - previousInput)
                previousInput = x
                previousOutput = hp
                let env = expf(-(Float(k) / sr) / 0.0035)
                let ramp: Float = k < strikeRamp ? 0.5 - 0.5 * cosf(.pi * Float(k) / Float(strikeRamp)) : 1
                let v = hp * env * ramp * note.strike * note.gain * 0.5
                channels[0][startIndex + k] += v
                channels[1][startIndex + k] += v
            }
        }

        for ch in 0..<2 {
            lowPass(&channels[ch], cutoffHz: recipe.toneCutoffHz)
            channels[ch] = reverb(channels[ch], wet: recipe.reverb, damping: recipe.reverbDamping, variant: ch)
        }

        // Tail fade.
        let fadeLength = min(Int(0.040 * sr), n)
        for k in 0..<fadeLength {
            let g = 0.5 + 0.5 * cosf(.pi * Float(k + 1) / Float(fadeLength))
            let i = n - fadeLength + k
            channels[0][i] *= g
            channels[1][i] *= g
        }

        // Normalise.
        var peak: Float = 0
        for ch in channels { for v in ch { peak = max(peak, abs(v)) } }
        if peak > 0 {
            let scale = recipe.peak / peak
            for ch in 0..<2 { for i in 0..<n { channels[ch][i] *= scale } }
        }
        return channels
    }

    /// Peak envelope of a rendered cue in `bins` equal time slices,
    /// normalised so the loudest bin is 1 — the little waveform the Settings
    /// cards draw.
    static func envelope(_ cue: Cue, theme: SoundTheme, bins: Int) -> [Float] {
        let channels = render(cue, theme: theme)
        let n = channels[0].count
        guard n > 0, bins > 0 else { return [] }
        var out = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            let lo = b * n / bins
            let hi = max(lo + 1, (b + 1) * n / bins)
            var peak: Float = 0
            for i in lo..<min(hi, n) {
                peak = max(peak, abs(channels[0][i]), abs(channels[1][i]))
            }
            out[b] = peak
        }
        let top = out.max() ?? 0
        if top > 0 { out = out.map { $0 / top } }
        return out
    }

    /// One-pole low-pass, in place. 0 Hz = bypass.
    private static func lowPass(_ x: inout [Float], cutoffHz: Float) {
        guard cutoffHz > 0 else { return }
        let a = 1 - expf(-2 * .pi * cutoffHz / sampleRate)
        var y: Float = 0
        for i in 0..<x.count {
            y += a * (x[i] - y)
            x[i] = y
        }
    }

    /// Small Schroeder-style room: three damped feedback combs into one
    /// allpass, 8 ms pre-delay, different delay sets per channel so the tail
    /// is decorrelated left/right. Sized for cues well under a second — the
    /// tail is ~0.35 s to −60 dB, and the render's duration cuts it anyway.
    private static func reverb(_ input: [Float], wet: Float, damping: Float, variant: Int) -> [Float] {
        guard wet > 0 else { return input }
        let n = input.count
        let combDelays = variant == 0 ? [1123, 1571, 1907] : [1277, 1733, 2053]
        let feedback: Float = 0.60

        var combSum = [Float](repeating: 0, count: n)
        for d in combDelays {
            var line = [Float](repeating: 0, count: n)
            var lowpass: Float = 0
            for i in 0..<n {
                let delayed = i >= d ? line[i - d] : 0
                lowpass = lowpass * damping + delayed * (1 - damping)
                line[i] = input[i] + lowpass * feedback
                combSum[i] += line[i]
            }
        }
        let combScale = 1 / Float(combDelays.count)

        let allpassDelay = variant == 0 ? 225 : 341
        let g: Float = 0.5
        var allpass = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = combSum[i] * combScale
            let delayedIn = i >= allpassDelay ? combSum[i - allpassDelay] * combScale : 0
            let delayedOut = i >= allpassDelay ? allpass[i - allpassDelay] : 0
            allpass[i] = -g * x + delayedIn + g * delayedOut
        }

        let predelay = Int(0.008 * sampleRate)
        var out = input
        if n > predelay {
            for i in predelay..<n {
                out[i] += wet * allpass[i - predelay]
            }
        }
        return out
    }

    /// Tiny deterministic generator for the tap noise.
    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func nextUnit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }
}
