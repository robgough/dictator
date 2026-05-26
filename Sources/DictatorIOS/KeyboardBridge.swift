import Foundation

/// Thin wrapper over the App Group shared `UserDefaults` that the
/// keyboard extension and host app use to exchange records / results.
///
/// Flow:
/// 1. Keyboard writes a request record (mode + session id + optional
///    surrounding text) into the shared defaults, then opens the host
///    app via `dictator://keyboard?session=...&mode=...`.
/// 2. Host reads the request, does the work (record + transcribe, or
///    transform an existing string), writes a result record back
///    keyed on the same session id.
/// 3. Keyboard polls the shared defaults on `viewWillAppear` (when the
///    user returns to the original app) and inserts the result via
///    `textDocumentProxy.insertText` if one is pending for the
///    current session.
///
/// Both sides MUST use the same App Group identifier — wired through
/// the entitlements files on each target.
enum KeyboardBridge {
    static let appGroupID = "group.net.robgough.DictatorIOS"

    /// Key the keyboard writes when it kicks off a session. Cleared
    /// by the host once consumed.
    private static let requestKey = "DictatorKeyboard.request"
    /// Host-side state heartbeat — keyboard reads this while polling
    /// to drive its in-flight UI.
    private static let hostStateKey = "DictatorKeyboard.hostState"
    /// Set by the keyboard when the user taps Stop. Host watches and
    /// short-circuits the recorder when it sees its own session id.
    private static let stopRequestKey = "DictatorKeyboard.stopRequest"
    /// Last-known model readiness — disk + memory status. Survives
    /// across host lifetimes (the keyboard reads this even when the
    /// host isn't running) but `loaded` is only trustworthy while
    /// the timestamp is fresh, since the model is in-process state.
    private static let modelReadinessKey = "DictatorKeyboard.modelReadiness"
    /// True while Dictator itself is the foreground app. Lets the
    /// keyboard extension self-dismiss when it would otherwise show
    /// up inside its own host app — confusing UX otherwise (open
    /// Dictator → tap into the transcript → Dictator keyboard
    /// summons → Dictator keyboard tries to launch Dictator…).
    /// Host writes via `.onChange(of: scenePhase)` in
    /// `DictatorIOSApp`; the timestamp lets the keyboard ignore
    /// stale values from a killed host.
    private static let hostActiveKey = "DictatorKeyboard.hostActive"
    /// Most recent text the host put on the system clipboard, paired
    /// with the pasteboard `changeCount` captured at write time.
    /// Lets the keyboard show a preview of "what tapping Paste will
    /// insert" without ever reading `UIPasteboard.general.string`
    /// itself (which triggers iOS's "Pasted from X" toast and a
    /// permission prompt on iOS 16+). If something else overwrites
    /// the clipboard the keyboard's local changeCount won't match
    /// the stored one and the preview hides itself.
    private static let lastDictationKey = "DictatorKeyboard.lastDictation"

    /// Snapshot of "what we just wrote to the system clipboard". The
    /// keyboard's preview pill renders `text` when the system
    /// pasteboard's current `changeCount` still equals
    /// `pasteboardChangeCount` — i.e. nothing else has overwritten
    /// the clipboard since the host wrote.
    struct LastDictation: Codable, Sendable, Equatable {
        var text: String
        var pasteboardChangeCount: Int
        var writtenAt: Date
    }

    private struct HostActiveState: Codable, Sendable {
        var active: Bool
        var updatedAt: Date
    }

    /// Recording or assist-transform — sent from the keyboard to the
    /// host so the host knows which flow to run when it foregrounds.
    enum Mode: String, Codable, Sendable, Equatable {
        case record
        case assist
    }

    /// Snapshot the keyboard hands over when it launches the host.
    /// `surroundingText` is what the keyboard could see around the
    /// cursor at request time — used by the assist flow as the
    /// transformation input.
    struct Request: Codable, Sendable, Equatable {
        var session: UUID
        var mode: Mode
        var surroundingText: String?
        var createdAt: Date
    }

    /// Model readiness snapshot the host publishes at lifecycle
    /// transitions (launch, download finish, model load, unload).
    /// Lets the keyboard tell the user whether the next dictation
    /// will be fast (model loaded + on disk), need a brief warmup
    /// (on disk, not loaded), or trigger a ~460 MB download.
    /// `loaded` is only trustworthy while the host is alive — the
    /// keyboard pairs it with `updatedAt` and treats stale entries
    /// as not-loaded.
    struct ModelReadiness: Codable, Sendable, Equatable {
        enum DiskStatus: String, Codable, Sendable, Equatable {
            case notDownloaded
            case downloaded
        }
        var diskStatus: DiskStatus
        var modelID: String
        var loaded: Bool
        var updatedAt: Date
    }

    /// Live in-flight signal the host writes during a keyboard-driven
    /// recording so the keyboard can render a recording / transcribing
    /// UI when the user switches back without waiting for the final
    /// result. Cleared when the result is written (or when recording
    /// is aborted), so its absence == "nothing in flight".
    struct HostState: Codable, Sendable, Equatable {
        enum Phase: String, Codable, Sendable, Equatable {
            case warmingUp
            case recording
            case transcribing
        }
        var session: UUID
        var phase: Phase
        /// Most recent RMS level (0...1) for the keyboard's pulse
        /// indicator. Updated by the host throttled to ~10 Hz so we
        /// aren't hammering UserDefaults at the audio buffer cadence.
        var level: Float
        var updatedAt: Date
    }

    /// Lazy shared UserDefaults pointing at the App Group. Returns
    /// `nil` only if the entitlement is missing or the App Group ID
    /// hasn't been provisioned — in which case the keyboard / host
    /// pair will silently be a no-op, so callers should always guard
    /// the `nil` case rather than force-unwrapping.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Keyboard side

    /// Called from the keyboard. Stages a request and returns the
    /// session id so the keyboard can match against `consumeResult`
    /// when the user comes back.
    @discardableResult
    static func enqueueRequest(mode: Mode, surroundingText: String?) -> UUID? {
        guard let defaults else { return nil }
        let request = Request(
            session: UUID(),
            mode: mode,
            surroundingText: surroundingText,
            createdAt: Date()
        )
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        defaults.set(data, forKey: requestKey)
        return request.session
    }

    // MARK: - Host side

    /// Host reads the latest request when it's foregrounded with a
    /// `dictator://keyboard?...` URL. Doesn't clear — the host
    /// clears via `clearRequest` only after the work has either
    /// succeeded (a result was written) or definitively failed.
    static func peekRequest() -> Request? {
        guard let defaults,
              let data = defaults.data(forKey: requestKey),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else { return nil }
        return request
    }

    /// Host clears a request without writing a result — used when
    /// the work failed in a way the user already saw, so we don't
    /// want the keyboard re-attempting on next focus.
    static func clearRequest() {
        guard let defaults else { return }
        defaults.removeObject(forKey: requestKey)
    }

    // MARK: - Host state heartbeat

    /// Host writes its current phase + level so the keyboard can
    /// render a recording UI when the user switches back. Cheap-
    /// enough at 10 Hz; callers should throttle to that cadence.
    static func writeHostState(_ state: HostState) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: hostStateKey)
    }

    static func readHostState() -> HostState? {
        guard let defaults,
              let data = defaults.data(forKey: hostStateKey),
              let state = try? JSONDecoder().decode(HostState.self, from: data)
        else { return nil }
        return state
    }

    static func clearHostState() {
        guard let defaults else { return }
        defaults.removeObject(forKey: hostStateKey)
    }

    // MARK: - Stop request

    /// Keyboard writes this when the user taps Stop. The host polls
    /// while recording and aborts when it sees a stop request.
    static func requestStop(session: UUID) {
        guard let defaults else { return }
        defaults.set(session.uuidString, forKey: stopRequestKey)
    }

    /// Host calls this once per poll tick. Returns true and clears
    /// the slot if any stop request is pending. No longer
    /// session-matched — with the host's keyboard-mode state gone,
    /// there's only one host process and at most one recording in
    /// flight, so the session ID is unnecessary disambiguation.
    static func consumeAnyStopRequest() -> Bool {
        guard let defaults,
              defaults.string(forKey: stopRequestKey) != nil
        else { return false }
        defaults.removeObject(forKey: stopRequestKey)
        return true
    }

    // MARK: - Model readiness

    static func writeModelReadiness(_ readiness: ModelReadiness) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(readiness) else { return }
        defaults.set(data, forKey: modelReadinessKey)
    }

    static func readModelReadiness() -> ModelReadiness? {
        guard let defaults,
              let data = defaults.data(forKey: modelReadinessKey),
              let readiness = try? JSONDecoder().decode(ModelReadiness.self, from: data)
        else { return nil }
        return readiness
    }

    // MARK: - Last dictation (clipboard preview hint)

    static func writeLastDictation(_ snapshot: LastDictation) {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: lastDictationKey)
    }

    static func readLastDictation() -> LastDictation? {
        guard let defaults,
              let data = defaults.data(forKey: lastDictationKey),
              let snapshot = try? JSONDecoder().decode(LastDictation.self, from: data)
        else { return nil }
        return snapshot
    }

    // MARK: - Host-active flag

    /// Host writes its current foreground state. Pair with the
    /// timestamp so the keyboard can ignore values from a long-dead
    /// host (iOS doesn't notify us when it kills a backgrounded app,
    /// so a flag without a freshness window could lie indefinitely).
    static func writeHostActive(_ active: Bool) {
        guard let defaults else { return }
        let state = HostActiveState(active: active, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: hostActiveKey)
    }

    /// True when the host wrote an `active = true` within the last
    /// 60 s. The freshness window is the only thing protecting us
    /// from a host that was active, got killed by iOS, and never
    /// got the chance to write `false` — the timestamp ages out
    /// and the keyboard stops auto-dismissing.
    static func isHostActive() -> Bool {
        guard let defaults,
              let data = defaults.data(forKey: hostActiveKey),
              let state = try? JSONDecoder().decode(HostActiveState.self, from: data)
        else { return false }
        guard Date().timeIntervalSince(state.updatedAt) < 60 else { return false }
        return state.active
    }
}
