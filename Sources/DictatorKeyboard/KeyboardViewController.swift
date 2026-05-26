import UIKit
import SwiftUI

/// Custom keyboard entry point. iOS hands every keyboard extension
/// a `UIInputViewController` instance to drive — we host a SwiftUI
/// view inside it and forward the press intents (mic / assist) up
/// to the controller, which knows how to launch the host app and
/// later consume the result via `KeyboardBridge`.
final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardRootView>?
    private var pendingSession: UUID?
    /// The most recent text the keyboard has fed into the field via
    /// `insertText`. Undo button delete-backwards by this many
    /// characters and clears the slot. Persists across re-renders
    /// (e.g. focus jumping between fields in the same app) so undo
    /// stays available until the user uses it or types over the
    /// inserted text manually.
    private var lastInsertedText: String?
    /// For assist-mode undo: the original text the result REPLACED,
    /// captured before we launched the host. Without this, undo on
    /// an assist insertion would just delete the transformed text
    /// and leave the field empty — defeating the point of undo.
    /// When non-nil, `undoLastInsertion` deletes the insertion AND
    /// re-inserts this so the field returns to its pre-assist state.
    private var lastReplacedText: String?
    /// Holds the surrounding text snapshot taken at `launchHost`
    /// time for assist mode, so when the result lands we can derive
    /// `lastReplacedText` from the suffix matching the result's
    /// `replacePrecedingCharacters` count. Cleared at the same time
    /// `pendingSession` is.
    private var pendingReplacedText: String?
    /// Cached host-state snapshot. Drives the in-flight UI (Stop
    /// button vs. mic/assist). Refreshed by the poll timer while the
    /// keyboard is visible.
    private var hostState: KeyboardBridge.HostState?
    /// Cached "is there something on the system clipboard?" so the
    /// always-on Paste pill can grey out when there's nothing to
    /// paste. Polled via the same timer as host state — cheap, and
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
    /// this, `refreshHostState` would only re-render on bridge
    /// changes and the button would stick enabled or disabled
    /// across typing.
    private var lastCanAssist: Bool = false
    /// Backspace press-and-hold state. `holdStartedAt` lets the
    /// running timer decide when to escalate from per-character to
    /// per-word deletion; `holdTimer` runs until the user releases.
    private var backspaceHoldStartedAt: Date?
    private var backspaceHoldTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        installSwiftUI()
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
        if KeyboardBridge.isHostActive() {
            advanceToNextInputMode()
            return
        }
        refreshHostState()
        startStatePolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopStatePolling()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        refreshHostState()
    }


    /// Pulls a fresh snapshot of the host's recording state out of
    /// the App Group container. Drives the keyboard's in-flight UI.
    /// The host writes this throttled at ~10 Hz while a keyboard
    /// session is in flight; clearing it (= nil here) means the
    /// recording finished, was cancelled, or never started.
    private func refreshHostState() {
        var next = KeyboardBridge.readHostState()
        // Treat a state record older than 10s as a dead host. The
        // host heartbeats every 3s while a keyboard session is in
        // flight (and throttles ~10Hz during actual recording), so
        // 10s comfortably covers any live state but flips the
        // keyboard UI back to idle quickly when the host crashed or
        // an early-return path forgot to tear the slot down — the
        // user shouldn't be stuck staring at a "listening" indicator
        // for 30s while nothing is actually happening.
        if let state = next, Date().timeIntervalSince(state.updatedAt) > 10 {
            KeyboardBridge.clearHostState()
            next = nil
        }
        // Recover the keyboard's own session when we missed it (e.g.
        // the keyboard view was re-instantiated by iOS after the
        // user switched apps).
        if pendingSession == nil, let session = next?.session {
            pendingSession = session
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
        let stateChanged = next != hostState
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
        if stateChanged || canAssistChanged || canPasteChanged || previewChanged {
            hostState = next
            canPaste = nextCanPaste
            pastePreview = nextPreview
            lastCanAssist = nextCanAssist
            refreshRootView()
        }
    }

    /// 300 ms polling while the keyboard is visible. Cheap — one
    /// UserDefaults read per tick. Stopped on viewWillDisappear so
    /// we don't burn battery in the background.
    private func startStatePolling() {
        stopStatePolling()
        statePollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshHostState()
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
        // We deliberately don't read text from the host field here.
        //   - `record` mode captures a fresh transcript, no context.
        //   - `assist` mode reads from the *system clipboard* in
        //     the host app (see RecordingViewModel.beginKeyboardRecording).
        //     We tried `textDocumentProxy.selectedText` and it's
        //     fundamentally unreliable across iOS apps (Radar
        //     FB7789012 — Apple's bridge silently truncates the
        //     selection to first+last sentence in WebView-backed
        //     fields like Mail body). The clipboard handoff is the
        //     only path that works the same everywhere.
        if mode == .assist {
            // Mark the current clipboard as "spent for assist" — the
            // button disables until the user copies again, so a
            // mistaken second tap can't silently re-act on the same
            // text. Refresh immediately so the disabled state is
            // visible on the same frame as the tap rather than
            // waiting up to a poll tick to flip.
            consumedAssistChangeCount = UIPasteboard.general.changeCount
            refreshHostState()
        }
        let surrounding: String? = nil
        let session = KeyboardBridge.enqueueRequest(
            mode: mode,
            surroundingText: surrounding
        )
        self.pendingSession = session
        // Stash the field's pre-launch contents so undo can put it
        // back. The host doesn't touch the field; it only writes a
        // result for us to insert, so this snapshot is still valid
        // when the result eventually lands.
        self.pendingReplacedText = surrounding

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
        lastReplacedText = nil
        pendingReplacedText = nil
        pendingSession = nil
        refreshRootView()
    }

    /// Undo the most recent paste — delete the inserted text and,
    /// for assist results (which replaced existing content), put
    /// the original text back so the field returns to its pre-assist
    /// state. Without the restore step, undo on an assist result
    /// would just leave the user with an empty field, which isn't
    /// what "undo" means.
    ///
    /// `String.count` is extended grapheme cluster count so one
    /// `deleteBackward` removes one composed character / emoji the
    /// user can see. Both slots clear after running so subsequent
    /// undo taps no-op until the next paste.
    private func undoLastInsertion() {
        guard let text = lastInsertedText, !text.isEmpty else { return }
        for _ in 0..<text.count {
            textDocumentProxy.deleteBackward()
        }
        if let replaced = lastReplacedText, !replaced.isEmpty {
            textDocumentProxy.insertText(replaced)
        }
        lastInsertedText = nil
        lastReplacedText = nil
        refreshRootView()
    }

    /// Re-render the SwiftUI keyboard so `canUndo`, hostState, etc.
    /// reflect the current state. UIHostingController is happy to
    /// have its rootView swapped at any time.
    private func refreshRootView() {
        hostingController?.rootView = makeRootView()
    }

    private func makeRootView() -> KeyboardRootView {
        KeyboardRootView(
            onMicPress: { [weak self] in self?.launchHost(mode: .record) },
            onAssistPress: { [weak self] in self?.launchHost(mode: .assist) },
            onStop: { [weak self] in self?.requestStopFromKeyboard() },
            onUndo: { [weak self] in self?.undoLastInsertion() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            canAssist: lastCanAssist,
            onBackspacePress: { [weak self] in self?.startBackspaceHold() },
            onBackspaceRelease: { [weak self] in self?.endBackspaceHold() },
            canUndo: lastInsertedText != nil,
            hostState: hostState,
            canPaste: canPaste,
            pastePreview: pastePreview,
            onPaste: { [weak self] in self?.pasteFromClipboard() }
        )
    }

    /// True when the system clipboard has text we can hand to the
    /// host for the assist flow. Reusing the same `hasStrings` check
    /// that drives the Paste pill — a single signal for "user has
    /// pre-staged content for us to work on" across the keyboard's
    /// two clipboard-consuming buttons. Reading `hasStrings` is
    /// metadata-only and does NOT trigger iOS's "Pasted from X"
    /// toast (only `string` does).
    private func hasTextToAssist() -> Bool {
        UIPasteboard.general.hasStrings
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

    /// Stop button in the in-flight UI. Writes a stop request the
    /// host's poller picks up. We also optimistically clear our local
    /// hostState so the keyboard UI flips back to idle immediately —
    /// without this, a host that crashed or got stuck (the user's
    /// "keyboard mode stuck in listening" report) would leave the
    /// keyboard staring at the stop button until the freshness
    /// window expired. If the host is alive and processing, its own
    /// teardown will keep the bridge clear too, so this is safe to
    /// do unconditionally on Stop.
    private func requestStopFromKeyboard() {
        guard let session = hostState?.session else { return }
        KeyboardBridge.requestStop(session: session)
        KeyboardBridge.clearHostState()
        hostState = nil
        refreshRootView()
    }
}
