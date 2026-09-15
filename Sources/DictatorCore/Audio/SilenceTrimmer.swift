import Foundation

/// Trims dead air off the front and back of a recording before it reaches the
/// ASR engine.
///
/// Two reasons this is worth doing, both of which show up on every single
/// dictation:
///
/// - **Latency.** A push-to-talk recording always carries the gap between
///   pressing the key and starting to speak, and the gap between finishing and
///   letting go. Whisper processes in fixed 30-second windows and Parakeet's
///   cost scales with sample count, so that dead air is paid for in full.
/// - **Hallucination.** Whisper is notorious for inventing text over silence —
///   "Thank you.", "Thanks for watching!" — because near-silent frames look
///   like the training data's outro music. Cutting the silence removes the
///   input that produces them.
///
/// Only the ends are touched. A pause in the *middle* of a dictation is
/// meaningful (it's where sentence boundaries are, and Whisper uses it), so
/// internal silence is never removed.
public enum SilenceTrimmer {

    public struct Result: Sendable {
        public let samples: [Float]
        /// Seconds removed from the start and end. Zero for both when the
        /// clip was left alone.
        public let leadingSecondsRemoved: Double
        public let trailingSecondsRemoved: Double

        public var didTrim: Bool { leadingSecondsRemoved > 0 || trailingSecondsRemoved > 0 }
        public var totalSecondsRemoved: Double { leadingSecondsRemoved + trailingSecondsRemoved }
    }

    /// Analysis window. 20 ms is short enough to place a word boundary
    /// accurately and long enough that a single noisy sample can't open the
    /// gate on its own.
    private static let frameMilliseconds = 20.0

    /// Speech kept either side of the detected span. Generous on purpose: a
    /// word's opening consonant ("s", "f", "th") is much quieter than its
    /// vowel, and clipping it changes what the model hears. Better to leave a
    /// little silence than to shave a syllable.
    private static let paddingSeconds = 0.15

    /// Never hand back anything shorter than this. If the gate only found a
    /// sliver of signal we'd rather send the whole clip and let the engine
    /// decide there was no speech in it.
    private static let minimumKeptSeconds = 0.30

    /// Below this much removed, skip the copy — the win isn't worth the
    /// allocation, and it keeps the log quiet on recordings that were already
    /// tight.
    private static let minimumWorthwhileTrim = 0.20

    /// Absolute floor on the speech threshold, so a recording made in a silent
    /// room with the gain down can't pick a threshold near zero and treat its
    /// own noise as speech.
    private static let absoluteThreshold: Float = 1e-4

    /// Trim leading and trailing silence. Returns the input untouched whenever
    /// trimming would be unsafe or pointless.
    public static func trim(_ samples: [Float], sampleRate: Double = 16_000) -> Result {
        let untouched = Result(samples: samples, leadingSecondsRemoved: 0, trailingSecondsRemoved: 0)
        let frameLength = max(1, Int(sampleRate * frameMilliseconds / 1000))
        guard samples.count > frameLength * 4 else { return untouched }

        // Per-frame RMS.
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameLength + 1)
        var start = 0
        while start < samples.count {
            let end = min(start + frameLength, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            levels.append((sum / Float(end - start)).squareRoot())
            start = end
        }
        guard levels.count >= 4 else { return untouched }

        // Threshold from the clip's own statistics rather than a fixed number:
        // a quiet USB mic and a hot audio interface differ by 30 dB, and a
        // constant would either shave speech off one or fail to trim the other.
        let sorted = levels.sorted()
        let noiseFloor = sorted[sorted.count / 5]          // 20th percentile
        let loud = sorted[(sorted.count * 19) / 20]        // 95th percentile
        // Speech peaks are an order of magnitude above room tone; a clip with
        // no such separation is either all speech or all silence, and in both
        // cases there's nothing safe to cut.
        guard loud > noiseFloor * 4 else { return untouched }
        let threshold = max(noiseFloor * 3, loud * 0.02, absoluteThreshold)

        guard let firstLoud = levels.firstIndex(where: { $0 >= threshold }),
              let lastLoud = levels.lastIndex(where: { $0 >= threshold })
        else { return untouched }

        let padFrames = max(1, Int(paddingSeconds * sampleRate) / frameLength)
        let startFrame = max(0, firstLoud - padFrames)
        let endFrame = min(levels.count - 1, lastLoud + padFrames)

        let startSample = startFrame * frameLength
        let endSample = min(samples.count, (endFrame + 1) * frameLength)
        guard endSample > startSample else { return untouched }

        let keptSeconds = Double(endSample - startSample) / sampleRate
        guard keptSeconds >= minimumKeptSeconds else { return untouched }

        let leading = Double(startSample) / sampleRate
        let trailing = Double(samples.count - endSample) / sampleRate
        guard leading + trailing >= minimumWorthwhileTrim else { return untouched }

        return Result(
            samples: Array(samples[startSample..<endSample]),
            leadingSecondsRemoved: leading,
            trailingSecondsRemoved: trailing
        )
    }
}
