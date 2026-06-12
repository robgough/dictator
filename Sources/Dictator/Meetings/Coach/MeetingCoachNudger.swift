import Foundation

/// One live coaching nudge, surfaced briefly on the island. Copy is terse
/// and factual — numbers, not judgement; chattiness in a mid-call
/// interruption is how the feature gets turned off.
struct CoachNudge: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case interrupting, dominating, monologue, pace
    }
    let kind: Kind
    let message: String
}

/// Deterministic rules over the signal snapshots: each nudge kind has a
/// trigger, a sustain (the condition must hold this long — instants don't
/// nag), a cooldown, and for the slow-burn kinds a minimum elapsed time so
/// nothing fires in the first awkward minutes of a call. At most one nudge
/// fires per evaluation, highest-priority first (the order of `Kind`'s
/// evaluation below).
///
/// Pure logic over `MeetingCoachSignals.Snapshot` — replay-harness friendly,
/// no actors, no Date(); all time comes from the snapshot's `elapsed`.
final class MeetingCoachNudger {
    struct Config {
        var monologueSeconds: Double = 90
        var monologueSustain: Double = 5
        var monologueCooldown: Double = 240

        /// ≥ this many fresh interruptions inside the trailing 5 minutes.
        var interruptionCount: Int = 2
        var interruptionCooldown: Double = 300
        /// Greetings are overlapping speech by nature — replay fired an
        /// interrupting nudge 9 s into a real call before this gate existed.
        var interruptionMinElapsed: Double = 120

        /// Hard floor between ANY two nudges, regardless of kind — per-kind
        /// cooldowns alone let an interruption-heavy meeting nag every few
        /// minutes (replay: 15 nudges in 36 min before this existed).
        var minSecondsBetweenNudges: Double = 150

        var dominateShare: Double = 0.70
        var dominateSustain: Double = 30
        var dominateCooldown: Double = 480
        var dominateMinElapsed: Double = 300
        /// Don't judge balance until the window holds this much total speech.
        var dominateMinWindowTalk: Double = 120

        /// Replay of the user's real meetings measured a ~220–230 wpm
        /// baseline — 280 sustained is meaningfully above their own normal,
        /// not a generic "average speaker" bar. Personal baselines are
        /// future trend work.
        var paceWPM: Double = 280
        var paceSustain: Double = 60
        var paceCooldown: Double = 480
        var paceMinElapsed: Double = 300
    }

    private let config: Config
    /// When each kind's trigger condition started holding (sustain tracking).
    private var holdingSince: [CoachNudge.Kind: Double] = [:]
    private var lastFiredAt: [CoachNudge.Kind: Double] = [:]
    /// Per-kind fire tally — cooldowns ESCALATE (double per repeat fire,
    /// capped ×8): the first reminder is information, the sixth is nagging.
    /// Replay of a genuinely interruption-heavy 36-min meeting: 6 same-kind
    /// nudges with flat cooldowns, 3 with escalation.
    private var fireCounts: [CoachNudge.Kind: Int] = [:]
    private var lastAnyFireAt: Double = -.infinity
    /// Interruption total at the last interrupting-nudge fire, so the same
    /// two interruptions can't re-fire after the cooldown without any new one.
    private var interruptionsAtLastFire = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Evaluate one snapshot; returns a newly-fired nudge or nil. Call once
    /// per engine tick (1 Hz).
    func evaluate(_ s: MeetingCoachSignals.Snapshot) -> CoachNudge? {
        let t = s.elapsed

        // Global rate limit before any per-kind logic.
        guard t - lastAnyFireAt >= config.minSecondsBetweenNudges else { return nil }

        // Interrupting — event-based, no sustain: the events already are.
        // Refiring needs a full fresh batch of NEW interruptions, not one
        // straggler after the cooldown.
        if t >= config.interruptionMinElapsed,
           s.interruptionsByMeLast5Min >= config.interruptionCount,
           s.interruptionsByMe >= interruptionsAtLastFire + config.interruptionCount,
           offCooldown(.interrupting, at: t, config.interruptionCooldown) {
            interruptionsAtLastFire = s.interruptionsByMe
            return fire(.interrupting, at: t,
                        "\(s.interruptionsByMeLast5Min) interruptions in 5 min — let them finish")
        }

        // Dominating — windowed share, sustained, not in the opening minutes.
        if t >= config.dominateMinElapsed,
           s.myTalkSeconds + s.theirTalkSeconds >= config.dominateMinWindowTalk,
           sustained(.dominating, holding: s.talkShareMeWindow >= config.dominateShare,
                     at: t, for: config.dominateSustain),
           offCooldown(.dominating, at: t, config.dominateCooldown) {
            return fire(.dominating, at: t,
                        "You're at \(Int((s.talkShareMeWindow * 100).rounded()))% of the last 10 min")
        }

        // Monologue — current run, lightly sustained so a boundary blip
        // doesn't fire it at 89.6 s.
        if sustained(.monologue, holding: s.currentMonologueSeconds >= config.monologueSeconds,
                     at: t, for: config.monologueSustain),
           offCooldown(.monologue, at: t, config.monologueCooldown) {
            return fire(.monologue, at: t,
                        "You've held the floor \(Int(s.currentMonologueSeconds))s — hand over?")
        }

        // Pace — sustained, against the user's own baseline.
        if t >= config.paceMinElapsed,
           let pace = s.paceWordsPerMinute,
           sustained(.pace, holding: pace >= config.paceWPM, at: t, for: config.paceSustain),
           offCooldown(.pace, at: t, config.paceCooldown) {
            return fire(.pace, at: t, "\(Int(pace.rounded())) wpm — slow down")
        }

        return nil
    }

    private func sustained(_ kind: CoachNudge.Kind, holding: Bool, at t: Double, for duration: Double) -> Bool {
        guard holding else {
            holdingSince[kind] = nil
            return false
        }
        let since = holdingSince[kind] ?? t
        holdingSince[kind] = since
        return t - since >= duration
    }

    private func offCooldown(_ kind: CoachNudge.Kind, at t: Double, _ cooldown: Double) -> Bool {
        let fires = fireCounts[kind] ?? 0
        let escalated = cooldown * pow(2, Double(min(max(0, fires - 1), 3)))
        return t - (lastFiredAt[kind] ?? -.infinity) >= escalated
    }

    private func fire(_ kind: CoachNudge.Kind, at t: Double, _ message: String) -> CoachNudge {
        lastFiredAt[kind] = t
        lastAnyFireAt = t
        fireCounts[kind, default: 0] += 1
        holdingSince[kind] = nil
        return CoachNudge(kind: kind, message: message)
    }
}
