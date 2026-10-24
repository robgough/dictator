import ActivityKit
import Foundation
import UIKit

/// Everything about Dictator holding the mic while it isn't the app in front.
///
/// Two things ride on the `audio` background mode:
///
/// 1. **A recording survives leaving the app or locking the phone.** Nothing
///    special is needed for that beyond the mode itself; this class adds the
///    Live Activity that shows it, and background-task runway so the
///    transcription after it isn't suspended half-way.
/// 2. **A warm session.** iOS won't let a backgrounded app *start* the mic,
///    so for the keyboard to dictate without bouncing through Dictator, the
///    engine has to already be running when the user leaves. After a
///    dictation, if the user has the keyboard set up and the setting is on,
///    the recorder stays armed (`IOSAudioRecorder.keepWarm`) with nothing
///    being kept, for `minutes` since last use. The mic indicator stays lit
///    for that whole time — that's the honest cost, and it's why the session
///    has a Live Activity with an off button and a visible expiry.
///
/// The keyboard learns about the session from a heartbeat in the App Group
/// (`KeyboardBridge.SessionState`), rewritten every second while anything is
/// live, so a host that iOS kills simply stops vouching for itself.
@MainActor
final class BackgroundSession {
    /// Called when a warm session times out with nothing in flight.
    var onExpire: (() -> Void)?

    private(set) var expiresAt: Date?
    private var expiryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var activity: Activity<DictationActivityAttributes>?
    private var runway: UIBackgroundTaskIdentifier = .invalid

    /// The last state published, re-sent by the heartbeat.
    private var state = KeyboardBridge.SessionState(phase: .ready, mode: nil, serving: nil, level: 0, expiresAt: nil, updatedAt: .distantPast)
    private var live = false
    private var lastLevelWrite = Date.distantPast
    private var recordingStartedAt: Date?
    private var lastSnippet: String?

    /// Minutes a warm session lasts after its last use; 0 turns it off.
    static var minutes: Int {
        UserDefaults.standard.integer(forKey: DictatorIOSSettings.backgroundSessionMinutesKey)
    }

    /// Whether the next recording should leave the mic warm when it ends.
    /// Only for people who use the keyboard: in-app dictation gains nothing
    /// from a warm mic, and nobody should get a lingering indicator for a
    /// feature they never touch.
    static var shouldKeepWarm: Bool {
        minutes > 0 && KeyboardBridge.keyboardRanWithFullAccess()
    }

    // MARK: - State from the view model

    /// Publish the current phase. `warm` is whether the recorder is armed
    /// for a session; with nothing capturing, transcribing or warm, the
    /// session is over and everything is torn down.
    func update(
        phase: KeyboardBridge.SessionState.Phase?,
        mode: KeyboardBridge.Mode?,
        serving: UUID?,
        warm: Bool
    ) {
        guard let phase else {
            // Nothing capturing or transcribing.
            if warm {
                extendExpiry()
                publish(.init(phase: .ready, mode: nil, serving: nil, level: 0, expiresAt: expiresAt, updatedAt: Date()))
            } else {
                stop()
            }
            return
        }
        // Calls that change nothing are dropped: republishing would
        // overwrite `updateLevel`'s write with a zero and leave the
        // keyboard's meter flat for a tick.
        let nextExpiry = warm ? expiresAt : nil
        if live, phase == state.phase, mode == state.mode, serving == state.serving, nextExpiry == state.expiresAt {
            return
        }
        if phase == .recording, state.phase != .recording { recordingStartedAt = Date() }
        if phase != .recording { recordingStartedAt = nil }
        let level = phase == .recording && state.phase == .recording ? state.level : 0
        publish(.init(phase: phase, mode: mode, serving: serving, level: level, expiresAt: nextExpiry, updatedAt: Date()))
        if phase == .transcribing {
            beginRunwayIfBackgrounded()
        } else {
            endRunway()
        }
    }

    /// Live mic level, throttled to 20 Hz — the keyboard draws its meter
    /// from it. The App Group write itself happens off the main actor (see
    /// `KeyboardBridge.writeSessionState`).
    func updateLevel(_ level: Float) {
        guard live, state.phase == .recording else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelWrite) > 0.05 else { return }
        lastLevelWrite = now
        state.level = level
        state.updatedAt = now
        KeyboardBridge.writeSessionState(state)
    }

    /// The first words of a result, for the lock screen.
    func noteResult(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        lastSnippet = words.isEmpty ? nil : words
        refreshActivity()
    }

    /// Tear everything down: heartbeat, expiry, Live Activity, runway.
    func stop() {
        guard live || activity != nil else { return }
        live = false
        expiresAt = nil
        expiryTask?.cancel()
        expiryTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        endRunway()
        KeyboardBridge.clearSessionState()
        endActivity()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Internals

    private func publish(_ next: KeyboardBridge.SessionState) {
        let phaseChanged = next.phase != state.phase || next.serving != state.serving || !live
        state = next
        live = true
        KeyboardBridge.writeSessionState(state, notify: phaseChanged)
        startHeartbeatIfNeeded()
        // Keep the screen awake while the user is talking to it. iOS only
        // honours this in the foreground, and nothing can stop the side
        // button locking the phone — but recording now carries on through
        // a lock anyway.
        UIApplication.shared.isIdleTimerDisabled = state.phase == .recording
        if activity == nil { startActivity() } else if phaseChanged { refreshActivity() }
    }

    private func extendExpiry() {
        let minutes = Self.minutes
        guard minutes > 0 else { return }
        expiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self else { return }
            // Never pull the mic out from under a capture; the next update
            // after it finishes re-arms the expiry.
            guard self.state.phase == .ready else { return }
            self.onExpire?()
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.live else { return }
                self.state.updatedAt = Date()
                KeyboardBridge.writeSessionState(self.state)
            }
        }
    }

    /// Transcription after a background stop must finish even if iOS would
    /// otherwise suspend us once the mic is released.
    private func beginRunwayIfBackgrounded() {
        guard runway == .invalid, UIApplication.shared.applicationState == .background else { return }
        runway = UIApplication.shared.beginBackgroundTask(withName: "DictatorFinishTranscription") { [weak self] in
            MainActor.assumeIsolated { self?.endRunway() }
        }
    }

    private func endRunway() {
        guard runway != .invalid else { return }
        UIApplication.shared.endBackgroundTask(runway)
        runway = .invalid
    }

    // MARK: - Live Activity

    private var contentState: DictationActivityAttributes.ContentState {
        let phase: DictationActivityAttributes.ContentState.Phase = switch state.phase {
        case .ready: .ready
        case .recording: .recording
        case .transcribing: .transcribing
        }
        return .init(phase: phase, expiresAt: state.expiresAt, recordingStartedAt: recordingStartedAt, lastSnippet: lastSnippet)
    }

    private func startActivity() {
        // ActivityKit only starts activities from the foreground. Recordings
        // begin in the foreground (or inside a session whose activity is
        // already up), so the cases this misses are ones with nothing new to
        // show.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background
        else { return }
        // A previous launch's activity can outlive the process; adopt
        // nothing from it, just clear it away.
        for stale in Activity<DictationActivityAttributes>.activities {
            Self.end(stale)
        }
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: .init(state: contentState, staleDate: state.expiresAt)
            )
        } catch {
            NSLog("[DictatorIOS] Live Activity request failed: \(error.localizedDescription)")
        }
    }

    private func refreshActivity() {
        guard let activity else { return }
        // `Activity` isn't Sendable, but its methods are safe from any
        // thread; this only quietens the region checker.
        nonisolated(unsafe) let target = activity
        let content = ActivityContent(state: contentState, staleDate: state.expiresAt)
        Task { await target.update(content) }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Self.end(activity)
    }

    private static func end(_ activity: Activity<DictationActivityAttributes>) {
        nonisolated(unsafe) let target = activity
        Task { await target.end(nil, dismissalPolicy: .immediate) }
    }
}
