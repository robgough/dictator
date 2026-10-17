import UIKit
import SwiftUI

/// Custom keyboard entry point. iOS hands every keyboard extension
/// a `UIInputViewController` instance to drive — we host a SwiftUI
/// view inside it and forward the press intents (mic / assist) up
/// to the controller, which knows how to launch the host app and
/// later consume the result via `KeyboardBridge`.
final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<AnyView>?
    /// Last-applied Full Access state. Drives a rebuild + height change when
    /// the user toggles "Allow Full Access" in Settings and returns. `nil`
    /// until the first `viewWillAppear`, so the first appearance always
    /// applies the correct layout. Without Full Access we show a basic typing
    /// keyboard (`KeyboardTypingView`); with it, the dictation pad
    /// (`KeyboardRootView`). Dictation can't work without Full Access (no mic,
    /// no host handoff), so the typing fallback is what keeps the extension
    /// useful — and satisfies App Review guideline 4.4.1.
    private var lastHadFullAccess: Bool?
    /// Explicit height constraint, active only in typing mode — the QWERTY
    /// layout is taller than iOS' default keyboard height, which would clip
    /// the bottom row otherwise. The dictation pad fits the default height, so
    /// we leave it unconstrained there.
    private var keyboardHeightConstraint: NSLayoutConstraint?
    /// The most recent text the keyboard has fed into the field via
    /// `insertText`. Undo button delete-backwards by this many
    /// characters and clears the slot. Persists across re-renders
    /// (e.g. focus jumping between fields in the same app) so undo
    /// stays available until the user uses it or types over the
    /// inserted text manually.
    private var lastInsertedText: String?
    /// The last dictation this keyboard inserted, as inserted, so the next
    /// one can finish its sentence (see `insertJoined`).
    private var lastDictation: String?
    /// Cached "is there something on the system clipboard?" so the
    /// always-on Paste pill can grey out when there's nothing to
    /// paste. Polled via the visible-while-active timer — cheap, and
    /// `UIPasteboard.hasStrings` doesn't trigger the iOS "Pasted from
    /// X" notification (only actually reading the value does).
    private var canPaste: Bool = false
    /// Pasteboard `changeCount` we last sent to the host as the
    /// assist source. The Assist button disables until the
    /// pasteboard ticks past this value — i.e. until the user
    /// explicitly copies something new. Stops a stray second Assist
    /// tap from re-acting on the same clipboard contents and stops
    /// "I selected something else but forgot to copy" from
    /// silently transforming the previous clipboard.
    /// `nil` means we haven't used the current clipboard yet.
    private var consumedAssistChangeCount: Int?
    /// Text to show in the keyboard's paste-preview pill — populated
    /// from the host's last-dictation snapshot whenever the system
    /// pasteboard's current `changeCount` still matches the count
    /// captured at write time. `nil` means "the clipboard has either
    /// been overwritten by another app or never received a Dictator
    /// transcript", so we don't claim to know what Paste would do.
    private var pastePreview: String?
    private var statePollTimer: Timer?
    /// Last-seen value of "field has text we can assist on", used
    /// to decide when to re-render the SwiftUI root so the Assist
    /// button's enabled state tracks the field content. Without
    /// this, `refreshKeyboardState` would only re-render on bridge
    /// changes and the button would stick enabled or disabled
    /// across typing.
    private var lastCanAssist: Bool = false
    /// True when the on-device foundation model is reachable —
    /// Apple Intelligence is supported on the hardware AND the user
    /// has turned it on AND the model has finished downloading. When
    /// false, we hide the Assist button entirely so the keyboard
    /// shows a single full-width Dictate tile rather than dangling a
    /// purple button that can never do anything. Re-queried on every
    /// `viewWillAppear` because the user can toggle Apple Intelligence
    /// in iOS Settings without restarting either process.
    private var assistSupported: Bool = isAssistCurrentlySupported()
    /// Backspace press-and-hold state. `holdStartedAt` lets the
    /// running timer decide when to escalate from per-character to
    /// per-word deletion; `holdTimer` runs until the user releases.
    private var backspaceHoldStartedAt: Date?
    private var backspaceHoldTimer: Timer?
    /// The host's background-session heartbeat (nil = no session: Dictate
    /// opens the app). Re-read on every refresh.
    private var sessionState: KeyboardBridge.SessionState?
    /// Recent levels for the recording meter, oldest first.
    private var levelHistory: [Float] = []
    /// A message about the last request that didn't produce text, shown in
    /// place of the buttons for a few seconds.
    private var notice: String?
    private var noticeHideTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Stamp the durable "this keyboard has run with Full Access"
        // proof. The write only succeeds when the user has granted
        // Open Access (otherwise the shared-container handle is nil
        // and it no-ops), so a successful write is exactly the signal
        // the host's onboarding uses to light up the Open Access step
        // — without it the host has no API to detect Full Access.
        KeyboardBridge.markKeyboardRanWithFullAccess()
        installSwiftUI()
        // The 300ms polling timer is the fallback, but copy events
        // also fire UIPasteboard.changedNotification — listening for
        // it means the Paste preview pill flips from "Empty" to the
        // user's snippet within one runloop tick of them tapping Copy,
        // instead of waiting up to 300ms for the next poll. The
        // notification fires in any process that has the pasteboard
        // observed, including a keyboard extension hosted by another
        // app, so an in-app copy inside Mail / Notes / Safari surfaces
        // immediately.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePasteboardChange),
            name: UIPasteboard.changedNotification,
            object: nil
        )
        // The host posts these the moment a session changes phase or a
        // result is ready, so Stop appears and text lands without waiting
        // for the next poll. Registered once per process; the handlers
        // reach whichever controller is current through `current`.
        Self.current = self
        Self.registerDarwinObserversOnce()
    }

    /// The live controller, for the process-wide Darwin observers.
    private static weak var current: KeyboardViewController?
    private static var darwinRegistered = false

    private static func registerDarwinObserversOnce() {
        guard !darwinRegistered else { return }
        darwinRegistered = true
        KeyboardBridge.observeDarwin(KeyboardBridge.sessionNotification) {
            current?.refreshKeyboardState()
        }
        KeyboardBridge.observeDarwin(KeyboardBridge.resultNotification) {
            current?.refreshKeyboardState()
        }
    }

    deinit {
        // `addObserver(_:selector:name:object:)` keeps a strong
        // reference to self until removed. UIInputViewController
        // can live for the lifetime of the keyboard process, but
        // belt-and-braces this — a re-instantiation by iOS during a
        // keyboard switch otherwise leaves a stale observer pointing
        // at a dead controller.
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handlePasteboardChange() {
        refreshKeyboardState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Bail BEFORE iOS finishes presenting if we're inside the
        // Dictator host app. The keyboard popping up over Dictator's
        // own UI is a confusing nesting; previously this check lived
        // in viewDidAppear and the user saw a flash of our keyboard
        // before the advance kicked in. viewWillAppear runs before
        // the present animation, so the system swaps to the next
        // keyboard without a visible blink.
        //
        // `isHostActive` reads a flag the host writes on scene-phase
        // transitions and heartbeats periodically while foregrounded
        // — the heartbeat is what keeps this check accurate beyond
        // the 60s freshness window when the user is sitting in
        // Dictator without backgrounding.
        let fullAccess = hasFullAccess

        // The host-active bounce and the dictation state machinery only make
        // sense with Full Access — without it the App Group and clipboard are
        // unreadable anyway.
        if fullAccess, KeyboardBridge.isHostActive() {
            advanceToNextInputMode()
            return
        }

        // Rebuild + resize when Full Access flips (the user can toggle it in
        // Settings and come back), and on the first appearance.
        if lastHadFullAccess != fullAccess {
            lastHadFullAccess = fullAccess
            applyKeyboardHeight(typing: !fullAccess)
            refreshRootView()
        }

        guard fullAccess else {
            // Typing fallback is pure document-proxy — no polling needed.
            stopStatePolling()
            return
        }

        // Re-check on every appearance so toggling Apple Intelligence
        // in iOS Settings updates the keyboard layout — the user goes
        // to Settings, flips it, switches back to their app, and the
        // next time the keyboard surfaces it picks up the new state.
        let nextAssistSupported = Self.isAssistCurrentlySupported()
        if nextAssistSupported != assistSupported {
            assistSupported = nextAssistSupported
            refreshRootView()
        }
        refreshKeyboardState()
        startStatePolling()
    }

    /// Reads the assist-availability boolean the host published into
    /// the App Group, instead of querying FoundationModels here. The
    /// keyboard extension deliberately doesn't link the Apple
    /// Intelligence framework — pulling it into the tightly
    /// memory-capped appex (and re-querying it on the 300ms poll)
    /// was a jetsam risk for no benefit, since the host already does
    /// the real `SystemLanguageModel.default.availability` check and
    /// publishes the binary result via `RecordingViewModel.publishModelReadiness`.
    /// Static so it can seed the stored property at declaration time.
    ///
    /// In DEBUG builds the developer override
    /// (`KeyboardBridge.debugForcedAssistAvailability`, set from
    /// Settings → Debug in the host app) takes precedence. It lives
    /// in `KeyboardBridge` and needs no FoundationModels symbols, so
    /// it's safe to read here. Stripped from release.
    ///
    /// Default conservatively to unavailable when the host has never
    /// published a value: a user can enable the keyboard in Settings
    /// before ever opening the host, in which case there's no
    /// snapshot yet. The host publishes on first launch / foreground,
    /// so the keyboard picks up the real value on its next appearance
    /// — better to show a single full-width Dictate tile briefly than
    /// to flash a greyed Assist button that may never light up.
    private static func isAssistCurrentlySupported() -> Bool {
        #if DEBUG
        if let forced = KeyboardBridge.debugForcedAssistAvailability {
            return forced == .available
        }
        #endif
        return KeyboardBridge.readAssistAvailable() ?? false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopStatePolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.current = self
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshKeyboardState()
    }

    /// Highlighting text lights up Assist straight away, rather than on
    /// the next poll tick.
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        refreshKeyboardState()
    }

    /// The text highlighted in the field, if any — Assist's first choice
    /// of what to rewrite, ahead of the clipboard. When the user has
    /// selected something, they've said what they mean; making them copy
    /// it too was only ever a workaround (see `launchHost`). The result
    /// replaces it, because inserting over a selection replaces it.
    #if DEBUG
    /// What the field handed the keyboard when Assist was tapped, and what
    /// happened when the result came back — lengths only, never the text.
    /// The last ten are kept in the App Group (`debug.assistProbes`) to be
    /// read off the phone when a field misbehaves (Mail's body, so far).
    private func recordAssistProbe(_ event: String, extra: [String: Any] = [:]) {
        let proxy = textDocumentProxy
        var entry: [String: Any] = [
            "at": Date().timeIntervalSince1970,
            "event": event,
            "selected": proxy.selectedText.map { ($0 as NSString).length } ?? -1,
            "before": proxy.documentContextBeforeInput.map { ($0 as NSString).length } ?? -1,
            "after": proxy.documentContextAfterInput.map { ($0 as NSString).length } ?? -1,
            "hasText": proxy.hasText,
        ]
        entry.merge(extra) { _, new in new }
        let defaults = UserDefaults(suiteName: KeyboardBridge.appGroupID)
        var probes = defaults?.array(forKey: "debug.assistProbes") as? [[String: Any]] ?? []
        probes.append(entry)
        defaults?.set(Array(probes.suffix(10)), forKey: "debug.assistProbes")
    }
    #else
    private func recordAssistProbe(_ event: String, extra: [String: Any] = [:]) {}
    #endif

    private func selectionForAssist() -> String? {
        guard let text = textDocumentProxy.selectedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }


    /// Re-derives the keyboard's clipboard-driven state — Paste
    /// enabled/preview and Assist enabled — from the system pasteboard
    /// and the host's last-dictation snapshot, and re-renders if any
    /// of it changed. Called on appear, on pasteboard-change
    /// notifications, on text changes, and on the visible-while-active
    /// poll tick. There's no longer any host-recording state to read:
    /// recording happens in Dictator's foreground, so the keyboard
    /// never shows an in-flight UI — it just opens the app and waits
    /// for the transcript to land on the clipboard.
    private func refreshKeyboardState() {
        guard hasFullAccess else { return }
        consumeResultIfReady()
        let nextSession = KeyboardBridge.readSessionState()
        // The meter scrolls on every poll, not only when the level changes,
        // so a held note still moves along like the app's waveform.
        if let nextSession, nextSession.phase == .recording {
            if sessionState?.phase != .recording { levelHistory = [] }
            levelHistory.append(nextSession.level)
            if levelHistory.count > 40 { levelHistory.removeFirst(levelHistory.count - 40) }
            if nextSession == sessionState { refreshRootView() }
        }
        if nextSession != sessionState {
            let pollFaster = nextSession?.phase == .recording
            let wasFaster = sessionState?.phase == .recording
            sessionState = nextSession
            refreshRootView()
            // A level meter at the 300 ms idle poll looks broken; tick
            // faster only while something is recording.
            if pollFaster != wasFaster, statePollTimer != nil { startStatePolling() }
        }
        // `hasStrings` and `changeCount` are both metadata-only —
        // neither triggers the "Pasted from X" notification (only
        // reading the actual string does, which we defer to an
        // explicit Paste tap).
        let nextCanPaste = UIPasteboard.general.hasStrings
        let currentChangeCount = UIPasteboard.general.changeCount
        // Paste preview derived from the host's last-dictation
        // snapshot. We only surface it when the system pasteboard's
        // current changeCount matches what the host captured — that
        // way "Hello world" doesn't keep showing as the preview
        // after the user has copied something else from another app.
        let nextPreview: String? = {
            guard let last = KeyboardBridge.readLastDictation() else { return nil }
            guard currentChangeCount == last.pasteboardChangeCount else { return nil }
            return last.text
        }()
        let canPasteChanged = nextCanPaste != canPaste
        let previewChanged = nextPreview != pastePreview
        // Assist enabled only when the user has copied something
        // the assist hasn't already acted on. Two filters:
        //
        //   1. Skip if the clipboard is what Dictator auto-wrote
        //      after the last transcription (its `changeCount`
        //      matches the stashed lastDictation record). Otherwise
        //      every successful assist would re-enable its own
        //      button via the auto-copy round-trip, defeating the
        //      whole "tap → disable" gesture.
        //
        //   2. Skip if we've already consumed this exact changeCount
        //      for an assist (`consumedAssistChangeCount`). Covers
        //      the case where the user taps Assist, the host bails
        //      before writing anything (no auto-copy), and we still
        //      don't want a second tap to re-run on the same text.
        //
        // Both gates clear when something *else* writes to the
        // clipboard — i.e. the user (or another app) genuinely
        // copied new content.
        let nextCanAssist: Bool = {
            // On hardware where assist will never light up (no Apple
            // Intelligence), short-circuit so the rest of the gating
            // logic doesn't run — and so the polling code never thinks
            // there's a state change to react to.
            guard assistSupported else { return false }
            // Highlighted text is the simplest source: no copying needed.
            if selectionForAssist() != nil { return true }
            guard nextCanPaste else { return false }
            if let last = KeyboardBridge.readLastDictation(),
               currentChangeCount == last.pasteboardChangeCount {
                return false
            }
            if let consumed = consumedAssistChangeCount,
               currentChangeCount == consumed {
                return false
            }
            return true
        }()
        let canAssistChanged = nextCanAssist != lastCanAssist
        // Pick up the assist-availability change inside the same
        // 300ms tick so the developer debug picker in Settings (or a
        // real-world Apple Intelligence toggle in iOS Settings)
        // doesn't need a viewWillAppear / keyboard switch to take
        // effect. Cheap — just a UserDefaults read in DEBUG and a
        // single property check otherwise.
        let nextAssistSupported = Self.isAssistCurrentlySupported()
        let assistSupportedChanged = nextAssistSupported != assistSupported
        if canAssistChanged || canPasteChanged || previewChanged || assistSupportedChanged {
            canPaste = nextCanPaste
            pastePreview = nextPreview
            lastCanAssist = nextCanAssist
            assistSupported = nextAssistSupported
            refreshRootView()
        }
    }

    /// 300 ms polling while the keyboard is visible. Cheap — one
    /// UserDefaults read per tick. Stopped on viewWillDisappear so
    /// we don't burn battery in the background.
    private func startStatePolling() {
        stopStatePolling()
        let interval = sessionState?.phase == .recording ? 0.05 : 0.3
        statePollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshKeyboardState()
        }
    }

    private func stopStatePolling() {
        statePollTimer?.invalidate()
        statePollTimer = nil
    }

    private func installSwiftUI() {
        let view = makeRootView()
        let controller = UIHostingController(rootView: view)
        controller.view.backgroundColor = .clear
        addChild(controller)
        view: do {
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            ])
        }
        controller.didMove(toParent: self)
        self.hostingController = controller
    }

    /// Launch the host app via custom URL scheme. The keyboard
    /// extension can use `open(_:completionHandler:)` (deprecated
    /// from inside an extension but still works for keyboard
    /// extensions with Open Access) by walking the responder chain
    /// to find a UIApplication. The responder-chain trick is fragile
    /// across iOS versions; we wrap it in a helper.
    private func launchHost(mode: KeyboardBridge.Mode) {
        // Assist's text: the selection if there is one, else the system
        // clipboard (read on the host side, see
        // RecordingViewModel.beginKeyboardRecording). The clipboard used to
        // be the only source — `textDocumentProxy.selectedText` was found to
        // truncate long selections in WebView-backed fields like a Mail body
        // (Radar FB7789012, 2020) — so it stays as the fallback for when
        // nothing is highlighted. `record` mode captures a fresh transcript
        // and needs no text.
        var selection: String?
        if mode == .assist {
            selection = selectionForAssist()
            recordAssistProbe("tap-cold", extra: ["source": selection == nil ? "clipboard" : "selection"])
            if selection == nil {
                // Mark the current clipboard as "spent for assist" — the
                // button disables until the user copies again, so a
                // mistaken second tap can't silently re-act on the same
                // text. Refresh immediately so the disabled state is
                // visible on the same frame as the tap rather than
                // waiting up to a poll tick to flip.
                consumedAssistChangeCount = UIPasteboard.general.changeCount
                refreshKeyboardState()
            }
        }
        let session = KeyboardBridge.enqueueRequest(
            mode: mode,
            surroundingText: selection
        )
        // The host hands the result back under this id, so when the user
        // returns here the text goes straight into the field.
        KeyboardBridge.setAwaiting(session)

        var components = URLComponents()
        components.scheme = "dictator"
        components.host = "keyboard"
        components.queryItems = [
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "session", value: session?.uuidString),
        ]
        guard let url = components.url else { return }
        openURL(url)
    }

    /// Walk the responder chain to find a `UIApplication` instance,
    /// then call its `open(_:options:completionHandler:)`. Required
    /// because `UIApplication.shared` is unavailable inside
    /// extensions, and `extensionContext?.open(_:)` is documented
    /// as not always working from custom keyboards specifically.
    /// The walk is a long-standing community workaround; it has
    /// kept working across iOS versions because the alternative
    /// would be to break every third-party keyboard that needs to
    /// open its host app.
    @discardableResult
    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        // Fallback for newer iOS versions where the walk doesn't
        // surface a UIApplication: extensionContext.open which is
        // the documented public API.
        extensionContext?.open(url, completionHandler: nil)
        return false
    }

    // MARK: - Dictating in place

    /// Dictate / Assist. With a warm background session the host records
    /// right away and this keyboard stays put; without one, open Dictator.
    private func requestDictation(mode: KeyboardBridge.Mode) {
        guard let session = KeyboardBridge.readSessionState(), session.phase == .ready else {
            launchHost(mode: mode)
            return
        }
        var sourceText: String?
        if mode == .assist {
            recordAssistProbe("tap-warm", extra: ["source": selectionForAssist() == nil ? "clipboard" : "selection"])
            if let selection = selectionForAssist() {
                sourceText = selection
            } else {
                // The host may be in the background, where it can't count
                // on reading the clipboard, so the keyboard reads it at tap
                // time. (This is what shows iOS's "pasted from" banner.)
                sourceText = UIPasteboard.general.string
                consumedAssistChangeCount = UIPasteboard.general.changeCount
            }
        }
        let id = UUID()
        KeyboardBridge.setAwaiting(id)
        KeyboardBridge.sendCommand(.init(id: id, action: .start, mode: mode, sourceText: sourceText, target: nil, createdAt: Date()))
        refreshKeyboardState()
    }

    private func sendSessionCommand(_ action: KeyboardBridge.Command.Action) {
        KeyboardBridge.sendCommand(.init(
            id: UUID(),
            action: action,
            mode: sessionState?.mode ?? .record,
            sourceText: nil,
            target: sessionState?.serving,
            createdAt: Date()
        ))
    }

    /// Insert the result the host produced for the request this keyboard
    /// is waiting on. A result older than a minute is left alone — it's on
    /// the clipboard, and the field in front of the user now may well not
    /// be the one they dictated for.
    private func consumeResultIfReady() {
        guard let awaiting = KeyboardBridge.awaiting(),
              let result = KeyboardBridge.takeResult(for: awaiting)
        else { return }
        KeyboardBridge.setAwaiting(nil)
        guard Date().timeIntervalSince(result.createdAt) < 60 else {
            recordAssistProbe("result-stale")
            return
        }
        if result.text?.isEmpty ?? true, result.error == nil {
            recordAssistProbe("result-empty")
        }
        if let text = result.text, !text.isEmpty {
            recordAssistProbe("result-before-insert", extra: ["result": (text as NSString).length])
            lastInsertedText = insertJoined(text)
            recordAssistProbe("result-after-insert")
            refreshRootView()
        } else if let error = result.error {
            recordAssistProbe("result-error", extra: ["error": error])
            showNotice(error)
        }
    }

    /// Insert a dictation so it sits properly against the text around the
    /// cursor — a space where it would glue onto a word, a lower-case start
    /// mid-sentence — using the same rules as the Mac's paste. The keyboard
    /// reads that text straight from the field, so this works in apps whose
    /// accessibility the Mac couldn't read. Returns what was inserted.
    ///
    /// One rule is the keyboard's own: a short dictation often comes back
    /// without a full stop, which is right for a one-line message but not
    /// when another dictation follows it. If the text before the cursor ends
    /// with the previous dictation, unpunctuated, and this one starts a new
    /// sentence, the previous one gets its full stop first.
    private func insertJoined(_ text: String) -> String {
        let proxy = textDocumentProxy
        // Assist replacing a highlighted passage: it goes exactly where the
        // highlight was.
        if let selected = proxy.selectedText, !selected.isEmpty {
            proxy.insertText(text)
            lastDictation = nil
            return text
        }
        var before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        if let previous = lastDictation?.trimmingCharacters(in: .whitespacesAndNewlines),
           let lastChar = previous.last, lastChar.isLetter || lastChar.isNumber,
           text.first?.isUppercase == true {
            let trailing = before.reversed().prefix(while: { $0 == " " }).count
            let trimmed = String(before.dropLast(trailing))
            if trimmed.hasSuffix(previous) {
                for _ in 0..<trailing { proxy.deleteBackward() }
                proxy.insertText(".")
                before = trimmed + "."
            }
        }
        let joined = InsertionJoiner.adjust(text, before: before, after: after)
        proxy.insertText(joined)
        lastDictation = joined
        return joined
    }

    private func showNotice(_ message: String) {
        notice = message
        refreshRootView()
        noticeHideTimer?.invalidate()
        noticeHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.notice = nil
            self?.refreshRootView()
        }
    }

    /// User tapped the always-on Paste pill. Reads the system
    /// clipboard and inserts it via `textDocumentProxy.insertText` —
    /// which replaces any active selection in the host field with
    /// the inserted text, so users can long-press to highlight a
    /// region before tapping Paste if they want a replacement
    /// instead of an insertion. iOS shows the standard "Dictator
    /// pasted from X" notification on this call; that's the price of
    /// any keyboard-extension paste.
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        lastInsertedText = text
        refreshRootView()
    }

    /// Undo the most recent paste — delete the inserted text.
    ///
    /// `String.count` is extended grapheme cluster count so one
    /// `deleteBackward` removes one composed character / emoji the
    /// user can see. The slot clears after running so subsequent
    /// undo taps no-op until the next paste.
    private func undoLastInsertion() {
        guard let text = lastInsertedText, !text.isEmpty else { return }
        for _ in 0..<text.count {
            textDocumentProxy.deleteBackward()
        }
        lastInsertedText = nil
        refreshRootView()
    }

    /// Re-render the SwiftUI keyboard so `canUndo`, the Paste pill,
    /// etc. reflect the current state. UIHostingController is happy to
    /// have its rootView swapped at any time.
    private func refreshRootView() {
        hostingController?.rootView = makeRootView()
    }

    /// The keyboard's content depends on Full Access: the dictation pad needs
    /// the App Group + clipboard (both Full-Access-only), so without it we fall
    /// back to a basic typing keyboard that drives only the text document proxy.
    private func makeRootView() -> AnyView {
        hasFullAccess ? AnyView(makeDictationView()) : AnyView(makeTypingView())
    }

    private func makeDictationView() -> KeyboardRootView {
        KeyboardRootView(
            onMicPress: { [weak self] in self?.requestDictation(mode: .record) },
            onAssistPress: { [weak self] in self?.requestDictation(mode: .assist) },
            session: sessionState,
            levels: levelHistory,
            notice: notice,
            onStop: { [weak self] in self?.sendSessionCommand(.stop) },
            onCancel: { [weak self] in self?.sendSessionCommand(.cancel) },
            onEndSession: { [weak self] in self?.sendSessionCommand(.end) },
            onUndo: { [weak self] in self?.undoLastInsertion() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            assistSupported: assistSupported,
            canAssist: lastCanAssist,
            onBackspacePress: { [weak self] in self?.startBackspaceHold() },
            onBackspaceRelease: { [weak self] in self?.endBackspaceHold() },
            canUndo: lastInsertedText != nil,
            canPaste: canPaste,
            pastePreview: pastePreview,
            onPaste: { [weak self] in self?.pasteFromClipboard() }
        )
    }

    private func makeTypingView() -> KeyboardTypingView {
        KeyboardTypingView(
            onInsert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            onDeletePress: { [weak self] in self?.startBackspaceHold() },
            onDeleteRelease: { [weak self] in self?.endBackspaceHold() },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            showsNextKeyboard: needsInputModeSwitchKey
        )
    }

    /// In typing mode the QWERTY layout is taller than iOS' default keyboard
    /// height; pin an explicit height so the bottom row isn't clipped. The
    /// dictation pad fits the default height, so we leave it unconstrained.
    /// Priority just below required so we never fight the system's own
    /// input-view constraints.
    private func applyKeyboardHeight(typing: Bool) {
        keyboardHeightConstraint?.isActive = false
        keyboardHeightConstraint = nil
        guard typing else { return }
        let constraint = view.heightAnchor.constraint(equalToConstant: 250)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        keyboardHeightConstraint = constraint
    }

    // MARK: - Backspace hold-to-repeat

    /// Initial press behaviour:
    /// - delete one character immediately (single-tap users get this)
    /// - schedule a 500 ms delay; on fire, switch to a 50 ms
    ///   character-repeat timer
    /// - after a further ~1500 ms held, escalate to 150 ms
    ///   word-by-word deletion
    /// Delays match the rhythm iOS uses for its own backspace key
    /// closely enough to feel native.
    private func startBackspaceHold() {
        backspaceHoldStartedAt = Date()
        textDocumentProxy.deleteBackward()
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.beginCharRepeat()
        }
    }

    private func beginCharRepeat() {
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let started = self.backspaceHoldStartedAt else { timer.invalidate(); return }
            // After ~2 s total hold, switch to word-by-word deletes.
            if Date().timeIntervalSince(started) > 2.0 {
                self.beginWordRepeat()
                return
            }
            self.textDocumentProxy.deleteBackward()
        }
    }

    private func beginWordRepeat() {
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.deleteWordBackward()
        }
    }

    /// Find the most recent word boundary and delete back to it.
    /// "Word" = a run of non-whitespace, possibly preceded by some
    /// whitespace we also want to swallow ("hello world " → "hello ").
    /// Reads `documentContextBeforeInput` to compute the right count;
    /// when it's nil (some host fields don't expose context), falls
    /// back to a single char delete so the keyboard still feels
    /// responsive.
    private func deleteWordBackward() {
        guard let before = textDocumentProxy.documentContextBeforeInput,
              !before.isEmpty
        else {
            textDocumentProxy.deleteBackward()
            return
        }
        let chars = Array(before)
        var i = chars.count - 1
        // Eat trailing whitespace first.
        while i >= 0 && chars[i].isWhitespace { i -= 1 }
        // Then eat the word itself.
        while i >= 0 && !chars[i].isWhitespace { i -= 1 }
        let toDelete = (chars.count - 1) - i
        // Belt-and-braces: never less than one delete (otherwise the
        // user would tap-and-tap and see nothing happen).
        let count = max(1, toDelete)
        for _ in 0..<count {
            textDocumentProxy.deleteBackward()
        }
    }

    private func endBackspaceHold() {
        backspaceHoldTimer?.invalidate()
        backspaceHoldTimer = nil
        backspaceHoldStartedAt = nil
    }
}
