import Foundation
import ApplicationServices

/// Notices when you fix one of Dictator's words by hand, and offers the fix as
/// a dictionary rule.
///
/// The flow is deliberately passive and slow:
///
/// 1. A dictation lands. Shortly after, we snapshot the focused field's whole
///    value — the text we delivered plus whatever surrounds it.
/// 2. `settleDelay` later, we read the same field again.
/// 3. `CorrectionDiff` re-locates our text using the untouched text either
///    side of it and reports single-word substitutions inside it.
/// 4. Anything that looks like a mis-hearing rather than a rewording becomes a
///    *suggestion* in Settings → Dictionary. Nothing is ever applied
///    automatically.
///
/// Nothing is stored but the two words: not the field, not the surrounding
/// document, not the app's contents. Both snapshots live in memory for the
/// length of the wait and are dropped immediately afterwards.
///
/// Off unless `settings.learnFromCorrectionsEnabled` is on, and inert without
/// Accessibility — the same permission the paste itself needs.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    /// How long to wait before re-reading. Long enough that the user has
    /// finished the sentence and gone back to fix the name, short enough that
    /// the field is probably still there. Corrections made later are missed,
    /// which is fine — the next dictation with the same word will catch it.
    private static let settleDelay: Duration = .seconds(25)

    /// Delay before the first snapshot. `TextInjector` posts ⌘V on a 40 ms
    /// delay and apps take a beat to update their text storage; 600 ms clears
    /// both comfortably without the user having had time to type.
    private static let pasteSettleDelay: Duration = .milliseconds(600)

    /// Fields longer than this are skipped outright. A correction inside a
    /// 200 kB document is not worth two reads of it, and the anchor search
    /// would be doing string scans proportional to the whole thing.
    /// `nonisolated` so the detached AX reads below can see it.
    private nonisolated static let maxFieldChars = 40_000

    /// AXUIElement is a CFType the Accessibility API explicitly permits
    /// calling from any thread — the calls are Mach IPC, and `AXContextReader`
    /// relies on the same property. Swift 6 can't know that, so the handle
    /// crosses into the detached read task inside this box.
    private struct ElementBox: @unchecked Sendable {
        let element: AXUIElement
    }

    private struct Pending {
        let box: ElementBox
        let fieldAfterPaste: String
        let delivered: String
        let appBundleID: String?
    }

    private var pending: Pending?
    private var task: Task<Void, Never>?

    private init() {}

    /// Start watching the focused field for hand-corrections to `delivered`.
    /// Safe to call on every dictation: a second call abandons the previous
    /// watch after giving it a chance to report (see `flush`).
    func watch(delivered: String, appBundleID: String?) {
        flush()
        guard AXIsProcessTrusted() else { return }
        let needle = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        // A one-word dictation gives the diff nothing to anchor on, and the
        // "did they change it" question collapses into "did they retype the
        // whole field".
        guard CorrectionDiff.words(needle).count >= 2 else { return }

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.pasteSettleDelay)
            guard !Task.isCancelled, let self else { return }
            guard let snapshot = await Self.readFocusedField() else { return }
            // The paste didn't land where we think it did (focus moved, the
            // app rewrote the field) — there's nothing to compare against.
            guard snapshot.value.contains(needle) else { return }
            self.pending = Pending(
                box: snapshot.box,
                fieldAfterPaste: snapshot.value,
                delivered: needle,
                appBundleID: appBundleID
            )

            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            guard let outstanding = self.pending else { return }
            self.pending = nil
            await self.evaluate(outstanding)
        }
    }

    /// Evaluate the outstanding watch now rather than waiting out the delay,
    /// and stop watching. Called when the next dictation starts — a
    /// dictate → fix → dictate-again loop is the most common way corrections
    /// happen, and waiting 25 s would miss every one of them.
    func flush() {
        task?.cancel()
        task = nil
        // Take the outstanding watch synchronously rather than letting the
        // spawned task read `pending` later: `watch` calls `flush` before
        // arming a new one, and reading the field after that would evaluate
        // the *new* dictation against the *old* snapshot.
        guard let outstanding = pending else { return }
        pending = nil
        Task { @MainActor [weak self] in await self?.evaluate(outstanding) }
    }

    /// Drop any outstanding watch without reporting. Used when the feature is
    /// switched off mid-wait.
    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func evaluate(_ pending: Pending) async {
        guard let now = await Self.readValue(pending.box) else { return }
        guard now != pending.fieldAfterPaste else { return }

        let changes = CorrectionDiff.changes(
            fieldAfterPaste: pending.fieldAfterPaste,
            fieldNow: now,
            delivered: pending.delivered
        )
        let corrections = changes.filter(CorrectionDiff.looksLikeCorrection)
        guard !corrections.isEmpty else { return }
        for change in corrections {
            CorrectionSuggestionStore.shared.record(
                heard: change.heard,
                corrected: change.corrected,
                appBundleID: pending.appBundleID
            )
        }
        NSLog("[Dictator] Learned %d correction candidate(s) from a hand-edit.", corrections.count)
    }

    // MARK: - Accessibility reads

    private struct Snapshot {
        let box: ElementBox
        let value: String
    }

    /// The focused element and its whole text value. Detached so a busy app
    /// can't stall the main actor; the messaging timeout bounds the worst case
    /// the same way `AXContextReader` does.
    private static func readFocusedField() async -> Snapshot? {
        await Task.detached(priority: .utility) { () -> Snapshot? in
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.25)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef else { return nil }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.25)

            // Never read password fields, exactly as the context reader
            // refuses to.
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            if (subroleRef as? String) == (kAXSecureTextFieldSubrole as String) { return nil }

            guard let value = Self.value(of: element) else { return nil }
            return Snapshot(box: ElementBox(element: element), value: value)
        }.value
    }

    private static func readValue(_ box: ElementBox) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            AXUIElementSetMessagingTimeout(box.element, 0.25)
            return Self.value(of: box.element)
        }.value
    }

    private nonisolated static func value(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let string = valueRef as? String,
              string.count <= maxFieldChars
        else { return nil }
        return string
    }
}
