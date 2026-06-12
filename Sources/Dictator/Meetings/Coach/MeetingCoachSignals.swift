import Foundation

/// Deterministic live conversation signals for the meeting coach: voice
/// activity per side, talk balance, monologue/interruption/silence tracking
/// from the recorders' level streams, plus pace/filler/question signals from
/// the live transcript lines.
///
/// Adds NO new audio capture or analysis — it consumes the same ~100×/s level
/// callbacks `MeetingSession` already receives to drive its meters, and the
/// `transcriptLines` the live transcriber already commits. Everything here is
/// arithmetic over streams that exist today.
///
/// Design rules:
///   - Pure logic, no actors, no Observation, no AppKit — the scratch replay
///     harness symlinks this file and drives it headless against recorded
///     meetings to tune thresholds.
///   - Every input carries an explicit timestamp (seconds since recording
///     start). The app stamps with its own clock; the harness replays file
///     time. Nothing in here reads Date().
///   - Mic VAD is bleed-discounted: on open speakers the mic hears the remote
///     side, so a hot mic only counts as *me* when its level isn't a small
///     fraction of the concurrent system level — the same separation
///     `MeetingLiveTranscriber.isLikelyBleed` uses for live ASR windows.
final class MeetingCoachSignals {
    struct Config {
        /// Level at/above which a side counts as voice, on the recorders'
        /// 0…1 RMS scale. Replay against real recordings (2026-06-12): 0.02
        /// tracks the transcript truth closely on normal meetings but misses
        /// very quiet mic setups; 0.01 recovers those but lets open-speaker
        /// bleed under the bar (interruptions 13→97 on one meeting). A fixed
        /// threshold can't serve both — phase 2 should grow an adaptive
        /// per-side noise floor; until then 0.02 is the safer default.
        var vadLevel: Float = 0.02
        /// A side stays "active" this long after its level last cleared the
        /// threshold, so inter-word dips don't flicker the VAD.
        var hangoverSeconds: Double = 0.35
        /// Mic-bleed separation, mirroring `MeetingLiveTranscriber`'s
        /// constants: below `bleedSystemFloor` the remote side is essentially
        /// quiet so a hot mic is genuinely me; otherwise my mic must reach
        /// `bleedFraction` × the concurrent system level to count as me.
        var bleedFraction: Float = 0.5
        var bleedSystemFloor: Float = 0.012
        /// Gaps under this don't break a monologue run.
        var monologueGapSeconds: Double = 2.0
        /// They must have held the floor this long before my voice starts for
        /// it to count as me interrupting…
        var interruptionMinTheirSeconds: Double = 1.0
        /// …my voice must then SUSTAIN this long before the interruption
        /// commits. Replay against real open-speaker meetings showed edge-
        /// only counting at ~10× the transcript truth — bleed spikes cross
        /// the VAD threshold for instants, real cut-ins persist.
        var interruptionSustainSeconds: Double = 0.7
        /// …and a fresh interruption isn't counted within this of the last
        /// (one sustained talk-over isn't five interruptions).
        var interruptionDebounceSeconds: Double = 3.0
        /// Rolling window for the windowed talk share.
        var windowSeconds: Double = 600
        /// Window over my recent transcript lines for pace/filler rates.
        var textWindowSeconds: Double = 120
    }

    /// Published state, recomputed on demand (the engine snapshots at 1 Hz).
    struct Snapshot: Equatable, Sendable {
        var elapsed: Double = 0
        /// Whole-meeting talk share (my speech / all speech), 0 when silent.
        var talkShareMe: Double = 0
        /// Talk share over the trailing `windowSeconds`.
        var talkShareMeWindow: Double = 0
        var myTalkSeconds: Double = 0
        var theirTalkSeconds: Double = 0
        /// Length of my current uninterrupted run, 0 when I'm not mid-run.
        var currentMonologueSeconds: Double = 0
        var longestMonologueSeconds: Double = 0
        var interruptionsByMe: Int = 0
        var interruptionsByMeLast5Min: Int = 0
        /// Seconds since anyone last spoke (0 while someone is speaking).
        var deadAirSeconds: Double = 0
        /// Words/min over my recent lines; nil until there's enough speech.
        var paceWordsPerMinute: Double? = nil
        var fillerWordsPerMinute: Double? = nil
        /// Seconds since my last question-shaped line; nil before the first
        /// transcript line ever arrives (no signal ≠ a 40-minute drought).
        var secondsSinceMyQuestion: Double? = nil
        var micActive: Bool = false
        var systemActive: Bool = false
    }

    let config: Config

    // MARK: Level/VAD state

    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0
    private var lastIngestAt: Double = 0

    private var micVoiceUntil: Double = -1     // last voice time + hangover
    private var sysVoiceUntil: Double = -1
    private var micActiveSince: Double?        // start of the current active stretch
    private var sysActiveSince: Double?

    // MARK: Accumulation

    /// 1-second activity bins (fraction of the second each side was active),
    /// indexed by floor(t). A 3-hour meeting is ~10.8k floats per side.
    private var micBins: [Double] = []
    private var sysBins: [Double] = []
    private var myTalkTotal: Double = 0
    private var theirTalkTotal: Double = 0

    private var monologueRunStart: Double?
    private var monologueRunEnd: Double = 0
    private var longestMonologue: Double = 0

    private var interruptionTimes: [Double] = []
    /// Rising edge of a would-be interruption, waiting out the sustain window.
    private var pendingInterruptionAt: Double?
    private var lastVoiceAt: Double = 0

    // MARK: Transcript-derived state

    private struct LineStats {
        var at: Double
        var words: Int
        var fillers: Int
    }
    private var myLineStats: [LineStats] = []
    private var lastMyQuestionAt: Double?
    private var sawAnyLine = false

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Ingest (levels)

    func ingestMic(level: Float, at t: Double) {
        lastMicLevel = level
        advance(to: t)
    }

    func ingestSystem(level: Float, at t: Double) {
        lastSystemLevel = level
        advance(to: t)
    }

    /// Move time forward to `t`, crediting the elapsed slice to whichever
    /// sides are currently active and updating run/event state. Levels arrive
    /// ~100×/s, so each slice is ~10 ms — fine to treat activity as constant
    /// across it.
    private func advance(to t: Double) {
        guard t >= lastIngestAt else { return }   // ignore clock weirdness
        let from = lastIngestAt
        lastIngestAt = t

        // Voice decisions from the current levels. Mic is bleed-discounted:
        // a hot mic while the remote side is loud and the mic is compar-
        // atively quiet is their voice arriving through my speakers.
        let micIsVoice = lastMicLevel >= config.vadLevel
            && (lastSystemLevel < config.bleedSystemFloor
                || lastMicLevel >= config.bleedFraction * lastSystemLevel)
        let sysIsVoice = lastSystemLevel >= config.vadLevel

        if micIsVoice { micVoiceUntil = t + config.hangoverSeconds }
        if sysIsVoice { sysVoiceUntil = t + config.hangoverSeconds }

        let micActive = t < micVoiceUntil
        let sysActive = t < sysVoiceUntil

        // Active-stretch bookkeeping (used by the interruption test below).
        if micActive { if micActiveSince == nil { micActiveSince = t } } else { micActiveSince = nil }
        if sysActive { if sysActiveSince == nil { sysActiveSince = t } } else { sysActiveSince = nil }

        // Interruption: my voice starting while they'd held the floor a while.
        // Two-stage — the rising edge only arms a pending interruption; it
        // commits when my voice sustains, and cancels if I go quiet first.
        // (Edge-only counting measured ~10× the transcript truth on real
        // open-speaker meetings: bleed spikes are instants, cut-ins persist.)
        if micActive, micActiveSince == t,
           let theirSince = sysActiveSince,
           t - theirSince >= config.interruptionMinTheirSeconds {
            pendingInterruptionAt = t
        }
        if !micActive {
            pendingInterruptionAt = nil
        } else if let pending = pendingInterruptionAt,
                  t - pending >= config.interruptionSustainSeconds {
            pendingInterruptionAt = nil
            if t - (interruptionTimes.last ?? -.infinity) >= config.interruptionDebounceSeconds {
                interruptionTimes.append(pending)
            }
        }

        // Credit the elapsed slice.
        let dt = t - from
        if dt > 0, dt < 5 {   // a long stall (paused process) shouldn't credit anyone
            if micActive { credit(&micBins, from: from, dt: dt); myTalkTotal += dt }
            if sysActive { credit(&sysBins, from: from, dt: dt); theirTalkTotal += dt }
        }
        if micActive || sysActive { lastVoiceAt = t }

        // Monologue runs: my activity extends the run; a gap longer than
        // monologueGapSeconds closes it.
        if micActive {
            if let start = monologueRunStart, t - monologueRunEnd > config.monologueGapSeconds {
                longestMonologue = max(longestMonologue, monologueRunEnd - start)
                monologueRunStart = t
            } else if monologueRunStart == nil {
                monologueRunStart = t
            }
            monologueRunEnd = t
        } else if let start = monologueRunStart, t - monologueRunEnd > config.monologueGapSeconds {
            longestMonologue = max(longestMonologue, monologueRunEnd - start)
            monologueRunStart = nil
        }
    }

    private func credit(_ bins: inout [Double], from: Double, dt: Double) {
        let second = max(0, Int(from))
        if bins.count <= second { bins.append(contentsOf: repeatElement(0, count: second - bins.count + 1)) }
        bins[second] = min(1, bins[second] + dt)
    }

    // MARK: - Ingest (transcript lines)

    /// Feed one committed live-transcript line. `isMe` mirrors the
    /// transcriber's Me/Them source labels; `t` is when the line committed
    /// (commit lags speech by a few seconds — fine for rate signals).
    func ingestLine(isMe: Bool, text: String, at t: Double) {
        sawAnyLine = true
        guard isMe else { return }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let fillers = CoachMetricsBuilder.fillerCount(in: text)
        myLineStats.append(LineStats(at: t, words: words, fillers: fillers))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            lastMyQuestionAt = t
        }
        // Cap memory across a very long meeting; rates only read the window.
        if myLineStats.count > 4096 { myLineStats.removeFirst(myLineStats.count - 2048) }
    }

    // MARK: - Snapshot

    func snapshot(at t: Double) -> Snapshot {
        var s = Snapshot()
        s.elapsed = t
        s.micActive = t < micVoiceUntil
        s.systemActive = t < sysVoiceUntil

        s.myTalkSeconds = myTalkTotal
        s.theirTalkSeconds = theirTalkTotal
        let total = myTalkTotal + theirTalkTotal
        s.talkShareMe = total > 0 ? myTalkTotal / total : 0

        let windowStart = max(0, Int(t - config.windowSeconds))
        let myWindow = sum(micBins, from: windowStart)
        let theirWindow = sum(sysBins, from: windowStart)
        let windowTotal = myWindow + theirWindow
        s.talkShareMeWindow = windowTotal > 0 ? myWindow / windowTotal : 0

        if let start = monologueRunStart, t - monologueRunEnd <= config.monologueGapSeconds {
            s.currentMonologueSeconds = monologueRunEnd - start
        }
        s.longestMonologueSeconds = max(longestMonologue, s.currentMonologueSeconds)

        s.interruptionsByMe = interruptionTimes.count
        s.interruptionsByMeLast5Min = interruptionTimes.count(where: { t - $0 <= 300 })

        s.deadAirSeconds = (s.micActive || s.systemActive) ? 0 : max(0, t - lastVoiceAt)

        // Pace/fillers over my recent lines, normalised by my *active* speech
        // time in the same window (bins, not wall clock — silence between my
        // lines shouldn't dilute the rate).
        let textWindowStart = max(0, Int(t - config.textWindowSeconds))
        let recent = myLineStats.filter { $0.at >= Double(textWindowStart) }
        let myActiveInWindow = sum(micBins, from: textWindowStart)
        if myActiveInWindow >= 20 {
            let words = recent.reduce(0) { $0 + $1.words }
            let fillers = recent.reduce(0) { $0 + $1.fillers }
            let minutes = myActiveInWindow / 60
            if words > 0 { s.paceWordsPerMinute = Double(words) / minutes }
            s.fillerWordsPerMinute = Double(fillers) / minutes
        }

        if sawAnyLine, let q = lastMyQuestionAt {
            s.secondsSinceMyQuestion = max(0, t - q)
        } else if sawAnyLine {
            s.secondsSinceMyQuestion = t   // lines flow but I've asked nothing yet
        }
        return s
    }

    private func sum(_ bins: [Double], from second: Int) -> Double {
        guard second < bins.count else { return 0 }
        return bins[second...].reduce(0, +)
    }
}
