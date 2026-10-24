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
    /// Sticky "the keyboard has run with Open/Full Access" proof. A
    /// keyboard extension can only read or write the App Group's
    /// shared `UserDefaults` once the user has granted Full Access —
    /// so the keyboard successfully writing *any* value here is
    /// itself the proof onboarding's step 5 needs. Monotonic: the
    /// keyboard sets it once it's live and the host NEVER clears it
    /// (a one-way "this happened at least once" signal — clearing it
    /// would re-arm a step the user already completed). Distinct from
    /// the request / readiness keys, which the host consumes and
    /// overwrites, so they can't serve as durable proof.
    private static let keyboardRanWithFullAccessKey = "DictatorKeyboard.keyboardRanWithFullAccess"
    /// Whether the host's last availability check found Apple
    /// Intelligence assist usable on this device. Published by the
    /// host (which can freely link FoundationModels) so the keyboard
    /// extension doesn't have to — keeping the Apple Intelligence
    /// framework out of the tightly memory-capped appex and off the
    /// keyboard's 300ms poll. The keyboard reads this to decide
    /// whether to show the Assist button at all.
    private static let assistAvailableKey = "DictatorKeyboard.assistAvailable"

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

    /// Lazy shared UserDefaults pointing at the App Group. Returns
    /// `nil` only if the entitlement is missing or the App Group ID
    /// hasn't been provisioned — in which case the keyboard / host
    /// pair will silently be a no-op, so callers should always guard
    /// the `nil` case rather than force-unwrapping.
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    #if DEBUG
    /// Developer override for the Apple Intelligence availability check.
    /// Set from Settings → Debug; read by both the host app
    /// (`AppleFoundationAssist.availability`) and the keyboard extension
    /// (`KeyboardViewController.isAssistCurrentlySupported`). When `nil`,
    /// both fall through to the real `SystemLanguageModel.default.availability`.
    /// Used to exercise the "Assist not available" UI on a simulator,
    /// which otherwise inherits the host Mac's Apple Intelligence
    /// support regardless of which iPhone model it's pretending to be.
    /// Stripped out of release builds entirely.
    enum DebugAssistAvailability: String {
        case available
        case notEnabled
        case deviceNotEligible
        case modelNotReady
    }

    private static let debugAssistAvailabilityKey = "debug.forced.assist.availability"

    static var debugForcedAssistAvailability: DebugAssistAvailability? {
        guard let raw = defaults?.string(forKey: debugAssistAvailabilityKey) else { return nil }
        return DebugAssistAvailability(rawValue: raw)
    }

    static func setDebugForcedAssistAvailability(_ value: DebugAssistAvailability?) {
        guard let defaults else { return }
        if let value {
            defaults.set(value.rawValue, forKey: debugAssistAvailabilityKey)
        } else {
            defaults.removeObject(forKey: debugAssistAvailabilityKey)
        }
    }
    #endif

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

    /// Called by the keyboard once it's live (e.g. `viewDidLoad`).
    /// The write only lands if Full Access is granted — when it's
    /// off, `defaults` is `nil` and this is a silent no-op — so a
    /// successful write is durable proof the access was on at least
    /// once. Idempotent: writing `true` repeatedly is harmless, and
    /// we never write `false` (the flag is one-way).
    static func markKeyboardRanWithFullAccess() {
        guard let defaults else { return }
        defaults.set(true, forKey: keyboardRanWithFullAccessKey)
    }

    /// Onboarding reads this to light up the "Open Access granted"
    /// step. True once the keyboard has ever written to the shared
    /// container with Full Access on. Never reset by the host — it's
    /// monotonic proof, not live state.
    static func keyboardRanWithFullAccess() -> Bool {
        guard let defaults else { return false }
        return defaults.bool(forKey: keyboardRanWithFullAccessKey)
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

    // MARK: - Assist availability

    /// Host publishes whether Apple Intelligence assist is usable on
    /// this device, computed from its own (FoundationModels-backed)
    /// availability check. Called wherever `publishModelReadiness` is
    /// — at launch and on each foreground — so the keyboard's button
    /// layout tracks the user toggling Apple Intelligence in Settings.
    static func writeAssistAvailable(_ available: Bool) {
        guard let defaults else { return }
        defaults.set(available, forKey: assistAvailableKey)
    }

    /// Keyboard reads the host's last-published assist availability.
    /// Returns `nil` when the host has never published — distinct
    /// from `false` so the caller can default conservatively (the
    /// user may have enabled the keyboard before ever opening the
    /// host). `UserDefaults.bool` would collapse "absent" into
    /// `false`, which happens to be the safe default here, but the
    /// optional keeps the "never published" case explicit at the
    /// call site.
    static func readAssistAvailable() -> Bool? {
        guard let defaults,
              defaults.object(forKey: assistAvailableKey) != nil
        else { return nil }
        return defaults.bool(forKey: assistAvailableKey)
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

    // MARK: - Background session (keyboard dictates in place)

    /// While Dictator holds a warm mic in the background (`BackgroundSession`),
    /// the keyboard can dictate without switching apps: it sends a `Command`,
    /// the host records and transcribes, and a `Result` comes back for the
    /// keyboard to insert straight into the field. `SessionState` is the
    /// host's heartbeat — its absence (or staleness) means "no session; the
    /// Dictate button has to open the app", which is the old flow.
    private static let sessionStateKey = "DictatorKeyboard.sessionState"
    private static let commandKey = "DictatorKeyboard.command"
    private static let resultKey = "DictatorKeyboard.result"
    /// The command (or URL-launch session) whose result the keyboard is
    /// waiting on. Lives in the App Group rather than the keyboard
    /// controller, because iOS often builds a fresh controller when the
    /// user switches back from Dictator to their app.
    private static let awaitingKey = "DictatorKeyboard.awaiting"

    /// Darwin notification names. Darwin notifications carry no payload —
    /// they only say "look in the App Group now" — and are delivered to a
    /// running process even while it's in the background, which is what
    /// lets a backgrounded host react to a keyboard tap at once.
    static let commandNotification = "net.robgough.DictatorIOS.keyboard.command"
    static let resultNotification = "net.robgough.DictatorIOS.keyboard.result"
    static let sessionNotification = "net.robgough.DictatorIOS.keyboard.session"

    struct SessionState: Codable, Sendable, Equatable {
        enum Phase: String, Codable, Sendable, Equatable {
            /// Mic warm, nothing being kept. The keyboard dictates in place.
            case ready
            case recording
            case transcribing
        }
        var phase: Phase
        /// What the in-flight capture is for, so the keyboard can show the
        /// right in-flight UI. nil while `.ready`.
        var mode: Mode?
        /// The command or URL-launch session being served. The keyboard
        /// only shows Stop for a capture it asked for.
        var serving: UUID?
        /// 0...1, only meaningful while `.recording`.
        var level: Float
        /// When the warm mic will be released if nothing else happens. nil
        /// for a recording that isn't part of a session (the setting is off).
        var expiresAt: Date?
        var updatedAt: Date
    }

    struct Command: Codable, Sendable, Equatable {
        enum Action: String, Codable, Sendable, Equatable {
            case start
            case stop
            case cancel
            /// Release the warm mic now.
            case end
        }
        var id: UUID
        var action: Action
        var mode: Mode
        /// Assist only: the text to transform. The keyboard reads the
        /// clipboard itself at tap time, because a backgrounded host can't
        /// rely on reading it.
        var sourceText: String?
        /// For `.stop` / `.cancel`: the capture to stop.
        var target: UUID?
        var createdAt: Date
    }

    struct Result: Codable, Sendable, Equatable {
        var serving: UUID
        var text: String?
        var error: String?
        var createdAt: Date
    }

    /// How long a heartbeat counts as live. The host rewrites the state at
    /// least every second while a session is up; a host that iOS has killed
    /// stops writing, and this is what stops the keyboard trusting it.
    static let sessionFreshness: TimeInterval = 4

    /// Session writes and clears, in the order they were made. The host
    /// writes the level 20 times a second while recording; encoding it and
    /// writing the App Group on the main actor cost frames, so it happens
    /// here. Serial, so a late level write can't land after a clear and
    /// bring a finished session back.
    private static let sessionWrites = DispatchQueue(label: "net.robgough.DictatorIOS.session-state", qos: .userInitiated)

    /// Publish the host's session state. `notify` posts the session Darwin
    /// notification once the write has landed, so the keyboard reads the
    /// new state rather than the one before it.
    static func writeSessionState(_ state: SessionState, notify: Bool = false) {
        sessionWrites.async {
            guard let defaults, let data = try? JSONEncoder().encode(state) else { return }
            defaults.set(data, forKey: sessionStateKey)
            if notify { postDarwin(sessionNotification) }
        }
    }

    static func clearSessionState() {
        sessionWrites.async {
            defaults?.removeObject(forKey: sessionStateKey)
            postDarwin(sessionNotification)
        }
    }

    /// The host's session heartbeat, or nil if there's no live session.
    static func readSessionState() -> SessionState? {
        guard let defaults,
              let data = defaults.data(forKey: sessionStateKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              Date().timeIntervalSince(state.updatedAt) < sessionFreshness
        else { return nil }
        if let expiresAt = state.expiresAt, expiresAt < Date(), state.phase == .ready { return nil }
        return state
    }

    /// Keyboard → host.
    static func sendCommand(_ command: Command) {
        guard let defaults, let data = try? JSONEncoder().encode(command) else { return }
        defaults.set(data, forKey: commandKey)
        postDarwin(commandNotification)
    }

    /// Host side: read and remove the pending command. Commands older than
    /// a few seconds are dropped — a tap the host never saw shouldn't fire
    /// a recording minutes later.
    static func takeCommand() -> Command? {
        guard let defaults, let data = defaults.data(forKey: commandKey) else { return nil }
        defaults.removeObject(forKey: commandKey)
        guard let command = try? JSONDecoder().decode(Command.self, from: data),
              Date().timeIntervalSince(command.createdAt) < 10
        else { return nil }
        return command
    }

    /// Host → keyboard.
    static func writeResult(_ result: Result) {
        guard let defaults, let data = try? JSONEncoder().encode(result) else { return }
        defaults.set(data, forKey: resultKey)
        postDarwin(resultNotification)
    }

    /// Keyboard side: the result for `serving`, removed once read so it's
    /// inserted exactly once.
    static func takeResult(for serving: UUID) -> Result? {
        guard let defaults,
              let data = defaults.data(forKey: resultKey),
              let result = try? JSONDecoder().decode(Result.self, from: data),
              result.serving == serving
        else { return nil }
        defaults.removeObject(forKey: resultKey)
        return result
    }

    static func setAwaiting(_ id: UUID?) {
        guard let defaults else { return }
        if let id {
            defaults.set(id.uuidString, forKey: awaitingKey)
        } else {
            defaults.removeObject(forKey: awaitingKey)
        }
    }

    static func awaiting() -> UUID? {
        defaults?.string(forKey: awaitingKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: - Darwin notifications

    static func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Run `handler` on the main queue whenever `name` is posted by any
    /// process. Observers live for the life of the process — both callers
    /// register once.
    static func observeDarwin(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        DarwinObservers.shared.add(name: name, handler: handler)
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

/// Holds Darwin-notification handlers. CFNotificationCenter takes a C
/// function pointer, which can't capture, so the callback looks the
/// handlers up here by name.
private final class DarwinObservers: @unchecked Sendable {
    static let shared = DarwinObservers()
    private let lock = NSLock()
    private var handlers: [String: [@MainActor () -> Void]] = [:]

    func add(name: String, handler: @escaping @MainActor () -> Void) {
        lock.lock()
        let first = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard first else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, cfName, _, _ in
                guard let raw = cfName?.rawValue as String? else { return }
                DarwinObservers.shared.fire(raw)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func fire(_ name: String) {
        lock.lock()
        let list = handlers[name] ?? []
        lock.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for handler in list { handler() }
            }
        }
    }
}
