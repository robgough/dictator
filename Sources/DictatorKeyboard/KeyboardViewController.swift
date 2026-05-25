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
    private var statePollTimer: Timer?
    /// Cached model-readiness snapshot from the host. Reused by the
    /// chip on the idle keyboard so the user can see whether the
    /// next dictation will be fast (loaded), need a warmup (on disk
    /// but not loaded), or trigger a download.
    ///
    /// Freshness is re-evaluated at render time inside
    /// `KeyboardRootView` against the timestamp on this record, so
    /// stale "ready" claims (host killed in background) downgrade
    /// the chip on the next lifecycle event — `viewWillAppear`,
    /// `textDidChange`, or the next bridge write from a live host.
    /// That covers every realistic transition without a polling
    /// flip-tracker.
    private var modelReadiness: KeyboardBridge.ModelReadiness?
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
        // Every time the keyboard becomes visible (initial focus, or
        // returning from a side-trip to the host app), check if there
        // is a staged result waiting. We only consume the result that
        // matches OUR most recent session, so a stale handoff from a
        // different keyboard session doesn't leak text into the
        // wrong field.
        applyPendingResult()
        refreshHostState()
        startStatePolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // If the user is inside the Dictator host app itself, the
        // Dictator keyboard popping up over Dictator's own UI is a
        // confusing nesting. We can't query iOS for "which app am
        // I in" from a keyboard extension, but the host writes a
        // foreground flag to the App Group on scene-phase changes
        // — when it's fresh and true, we know we're inside Dictator
        // and immediately advance to the next keyboard. iOS will
        // pick whichever the user has next in their keyboard
        // ordering, usually the system default.
        if KeyboardBridge.isHostActive() {
            advanceToNextInputMode()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopStatePolling()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // Re-check on focus changes too — `viewWillAppear` doesn't
        // always fire when the focus jumps between fields in the
        // same app, but `textDidChange` does.
        applyPendingResult()
        refreshHostState()
    }

    /// Pulls a fresh snapshot of the host's recording state out of
    /// the App Group container. Drives the keyboard's in-flight UI.
    /// The host writes this throttled at ~10 Hz while a keyboard
    /// session is in flight; clearing it (= nil here) means the
    /// recording finished, was cancelled, or never started.
    private func refreshHostState() {
        var next = KeyboardBridge.readHostState()
        // Treat a state record older than 30s as a dead host — the
        // host writes a heartbeat every 3s while a keyboard session
        // is in flight, so anything past 30s means the host crashed
        // or was killed in the app switcher and we'd otherwise sit
        // on the in-flight UI forever. The generous window leaves
        // plenty of headroom for long transcriptions, which are the
        // main reason an old "60s = dead" threshold wouldn't fly.
        if let state = next, Date().timeIntervalSince(state.updatedAt) > 30 {
            KeyboardBridge.clearHostState()
            next = nil
        }
        // Recover the keyboard's own session when we missed it (e.g.
        // the keyboard view was re-instantiated by iOS after the user
        // switched apps). Lets `applyPendingResult` find the result
        // we wrote for that session.
        if pendingSession == nil, let session = next?.session {
            pendingSession = session
        }
        // Model readiness changes much less often than host state,
        // but reading on the same poll tick is cheaper than wiring a
        // separate timer.
        let nextReadiness = KeyboardBridge.readModelReadiness()
        let stateChanged = next != hostState
        let readinessChanged = nextReadiness != modelReadiness
        // Assist button enable/disable is a function of field
        // contents, which changes outside the bridge entirely; check
        // it here so a poll tick after `textDidChange` re-renders
        // when needed.
        let nextCanAssist = hasTextToAssist()
        let canAssistChanged = nextCanAssist != lastCanAssist
        if stateChanged || readinessChanged || canAssistChanged {
            hostState = next
            modelReadiness = nextReadiness
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
            self?.applyPendingResult()
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
        // Capture the immediately-preceding text for assist so the
        // host has something to transform. For record we don't
        // attach the surrounding text — it would be confusing to
        // include in the new transcript.
        let surrounding = mode == .assist
            ? textDocumentProxy.documentContextBeforeInput
            : nil
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

    /// Pull a result for our session out of the shared container, if
    /// one exists. Inserts the text via `textDocumentProxy` and
    /// (for assist) deletes the right number of preceding chars so
    /// the transformation visually replaces the input. Tracks what
    /// it inserted in `lastInsertedText` so the undo button can rip
    /// it back out if the user dislikes the result.
    private func applyPendingResult() {
        guard let result = KeyboardBridge.consumeResult(matching: pendingSession) else {
            return
        }
        for _ in 0..<result.replacePrecedingCharacters {
            textDocumentProxy.deleteBackward()
        }
        // Append a trailing space so the next dictation starts after
        // a clear word boundary instead of smushing into the last
        // word of this insertion. Skip when the result already ends
        // in whitespace (the user said "new paragraph", or the model
        // padded it) OR when we're replacing existing text — assist
        // transformations land in-place and tacking on a stray space
        // breaks the surrounding sentence.
        var inserted = result.text
        let shouldAppendSpace = result.replacePrecedingCharacters == 0
            && !(inserted.last?.isWhitespace ?? true)
        if shouldAppendSpace {
            inserted += " "
        }
        textDocumentProxy.insertText(inserted)
        // Tracked with the trailing space included — Undo wipes the
        // entire insertion as one unit, leaving the field exactly as
        // it was before.
        lastInsertedText = inserted
        // For assist (replacement) results, hold onto the suffix of
        // the pre-launch text that the host transformed away, so
        // undo can restore the original. Use the suffix matching
        // `replacePrecedingCharacters` rather than the whole
        // captured string in case the host trimmed leading content.
        if result.replacePrecedingCharacters > 0,
           let original = pendingReplacedText
        {
            lastReplacedText = String(original.suffix(result.replacePrecedingCharacters))
        } else {
            lastReplacedText = nil
        }
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
            canAssist: hasTextToAssist(),
            onBackspacePress: { [weak self] in self?.startBackspaceHold() },
            onBackspaceRelease: { [weak self] in self?.endBackspaceHold() },
            canUndo: lastInsertedText != nil,
            hostState: hostState,
            modelReadiness: modelReadiness
        )
    }

    /// True when there's at least one non-whitespace character
    /// before the cursor — i.e. something for assist to transform.
    /// Pulled from `documentContextBeforeInput`; for fields that
    /// don't expose context (some secure inputs), errs on the side
    /// of enabled so the user isn't blocked from trying.
    private func hasTextToAssist() -> Bool {
        guard let before = textDocumentProxy.documentContextBeforeInput else {
            // Field doesn't expose context; can't tell, don't gate.
            return true
        }
        return !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// host's poller picks up; UI flips back to mic/assist on the
    /// next poll when the host clears its in-flight slot.
    private func requestStopFromKeyboard() {
        guard let session = hostState?.session else { return }
        KeyboardBridge.requestStop(session: session)
    }
}
