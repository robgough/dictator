import Foundation

/// Per-track word streams captured before the destructive cleanup passes
/// (bleed-cluster drop, echo dedup), plus the mic-bleed gate's diagnostics.
/// One `tracks.json` per meeting folder, written on every (re)process by the
/// macOS pipeline and rendered by the transcript page's "Tracks" mode — the
/// two transcriptions side by side in time, with exactly what each cleanup
/// stage removed still visible.
struct MeetingTrackInspection: Codable, Equatable, Sendable {
    /// Why a word was excluded from the merged transcript. Raw values are
    /// stored on disk — keep them stable.
    enum DropReason: String, Codable, Sendable {
        /// The word's diarizer cluster matched a remote (system-track) voice
        /// and only spoke during system activity — mic bleed; the system
        /// track carries the clean copy of this speech.
        case bleedCluster = "bleed-cluster"
        /// Word-level echo dedup: the same word appears on the system track
        /// within the match window.
        case echoDedup = "echo-dedup"
    }

    struct Word: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
        /// Unified speaker ID ("me", "speaker_N", or the bleed sentinel for
        /// words the backstop removed).
        var speakerId: String
        /// nil when the word survived into the merged transcript.
        var dropped: DropReason?

        init(start: Double, end: Double, text: String, speakerId: String, dropped: DropReason? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.speakerId = speakerId
            self.dropped = dropped
        }
    }

    struct TimeRange: Codable, Equatable, Sendable {
        var start: Double
        var end: Double

        init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Mic-bleed gate diagnostics (audio-domain pass, runs before ASR — its
    /// removals are time ranges, not words: the silenced audio was never
    /// transcribed).
    struct GateInfo: Codable, Equatable, Sendable {
        var applied: Bool
        /// Best lag-aligned log-envelope correlation between the tracks.
        var correlation: Double
        /// Mic-vs-system start offset (seconds) removed to align the tracks.
        var offsetSeconds: Double
        /// Estimated bleed coupling (bleed level ÷ system level).
        var gain: Double
        /// Fraction of mic frames silenced.
        var droppedFraction: Double
        /// Times (on the aligned timeline) where mic audio was silenced.
        var silencedRanges: [TimeRange]

        init(applied: Bool, correlation: Double, offsetSeconds: Double, gain: Double,
             droppedFraction: Double, silencedRanges: [TimeRange]) {
            self.applied = applied
            self.correlation = correlation
            self.offsetSeconds = offsetSeconds
            self.gain = gain
            self.droppedFraction = droppedFraction
            self.silencedRanges = silencedRanges
        }
    }

    var schemaVersion: Int
    var mic: [Word]
    var system: [Word]
    var gate: GateInfo?
    /// Median 10 ms speech RMS per track (mic measured post-gate, so it
    /// reflects the user's voice, not bleed). Drives playback normalization:
    /// the mic typically runs far quieter than the digitally-hot call audio.
    /// nil on tracks too short/quiet to measure, and on pre-existing files.
    var micSpeechLevel: Double?
    var systemSpeechLevel: Double?

    static let currentSchemaVersion = 1

    init(mic: [Word], system: [Word], gate: GateInfo?,
         micSpeechLevel: Double? = nil, systemSpeechLevel: Double? = nil,
         schemaVersion: Int = MeetingTrackInspection.currentSchemaVersion) {
        self.mic = mic
        self.system = system
        self.gate = gate
        self.micSpeechLevel = micSpeechLevel
        self.systemSpeechLevel = systemSpeechLevel
        self.schemaVersion = schemaVersion
    }
}
