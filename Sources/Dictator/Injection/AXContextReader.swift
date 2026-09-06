import Foundation
import ApplicationServices

/// Reads `InsertionContext` off the focused UI element. Stateless; safe to
/// call from any thread (the AX C API is Mach-message IPC) — callers run it
/// in a detached task so an unresponsive frontmost app can't stall the main
/// actor, with `AXUIElementSetMessagingTimeout` bounding the worst case.
enum AXContextReader {
    /// Caps for the formatter-prompt capture. Sized for the small local
    /// models: enough preceding text to establish terminology and topic
    /// (~250 tokens), a glance of what follows. Wispr-style six-figure caps
    /// would drown a 1–4 B model's prompt.
    static let promptBeforeCap = 1000
    static let promptAfterCap = 200

    /// Caps for the delivery-time join snapshot. Join decisions only need the
    /// current line plus enough surrounding words to spot proper-noun
    /// evidence for the capitalisation call.
    static let joinBeforeCap = 256
    static let joinAfterCap = 64

    /// Caps for the term-mining sweep (press-time capture only). Much wider
    /// than the prose window: a name spelled "Siobhán" three pages up is
    /// just as authoritative as one in the previous sentence, and a mined
    /// term list costs a handful of prompt tokens regardless of how much
    /// document it was distilled from. Single ranged AX reads — cheap.
    static let mineBeforeCap = 16_000
    static let mineAfterCap = 4_000

    /// Per-call ceiling on AX round-trips to a busy app. Generous for the
    /// normal case (microseconds); short enough that a beachballing app
    /// can't hold up the capture task for long.
    private static let messagingTimeout: Float = 0.25

    /// Returns nil when Accessibility isn't granted, nothing text-like is
    /// focused, the focused element is a secure (password) field, or the
    /// element doesn't support ranged text reads (Electron apps with the
    /// accessibility tree off, canvas editors like Google Docs, terminals).
    /// Callers treat nil as "no context this run" — the feature is
    /// opportunistic seasoning, never load-bearing.
    ///
    /// `mineTerms` additionally sweeps a much wider document slice for
    /// distinctive terminology (see `DocumentTerms`) — wanted at press time
    /// for the formatter, pointless for the delivery-time join snapshot.
    ///
    /// `requireFieldAccurate` demands the ranged reads describe the exact
    /// field the paste will land in — set by the delivery-time join snapshot,
    /// whose character-level spacing/casing decisions go visibly wrong on a
    /// misaligned read. The prompt capture doesn't set it: page-level text is
    /// still legitimate spelling/terminology context.
    static func capture(maxBefore: Int, maxAfter: Int, mineTerms: Bool = false,
                        requireFieldAccurate: Bool = false) -> InsertionContext? {
        captureDetailed(maxBefore: maxBefore, maxAfter: maxAfter, mineTerms: mineTerms,
                        requireFieldAccurate: requireFieldAccurate).context
    }

    /// Like `capture`, but also returns a short, user-facing reason when it
    /// comes back without text — surfaced in the assistant result window's
    /// context banner so an empty read is debuggable rather than a silent
    /// "no cursor text". `reason` is nil on a successful read.
    static func captureDetailed(maxBefore: Int, maxAfter: Int, mineTerms: Bool = false,
                                requireFieldAccurate: Bool = false)
        -> (context: InsertionContext?, reason: String?)
    {
        guard AXIsProcessTrusted() else {
            NSLog("[Dictator] Context capture: no Accessibility permission.")
            return (nil, "Accessibility permission is off")
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else {
            NSLog("[Dictator] Context capture: no focused element (AXError %d).", err.rawValue)
            return (nil, "no focused text field")
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        // If the focused element belongs to Dictator itself — the assistant
        // result window had key focus when the hotkey fired — we'd be reading
        // our own window, not the user's app. Surface that rather than a
        // confusing empty (the fix is to click back into the app first).
        var elementPID: pid_t = 0
        if AXUIElementGetPid(element, &elementPID) == .success,
           elementPID == ProcessInfo.processInfo.processIdentifier {
            NSLog("[Dictator] Context capture: focused element is Dictator's own window — no app context.")
            return (nil, "focused on Dictator, not your app")
        }

        // Never read password fields. (They expose a masked/empty value by
        // design, but we don't even ask.)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == (kAXSecureTextFieldSubrole as String) {
            NSLog("[Dictator] Context capture: focused element is a secure field — skipped.")
            return (nil, "a password field")
        }

        // No role allowlist beyond the secure-field exclusion: text fields,
        // text areas, combo boxes, and WebKit's AXWebArea all answer the
        // ranged reads below, and anything that can't simply fails them —
        // which collapses to the same nil as "no context available".
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, let rangeValue = rangeRef else {
            NSLog("[Dictator] Context capture: focused element has no selected-text range (AXError %d) — no context.", rangeErr.rawValue)
            return (nil, "this field exposes no text cursor")
        }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection),
              selection.location >= 0 else {
            NSLog("[Dictator] Context capture: selected-text range undecodable or negative — no context.")
            return (nil, "this field exposes no text cursor")
        }

        // Total length, for clamping the after-read. Some elements omit it;
        // an over-long range request then just comes back short or fails,
        // which is fine.
        var total = Int.max
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = (countRef as? NSNumber)?.intValue {
            total = n
        }
        guard selection.location <= total else {
            NSLog("[Dictator] Context capture: selection past end of text — no context.")
            return (nil, "this field exposes no text cursor")
        }

        let beforeStart = max(0, selection.location - maxBefore)
        let before = string(of: element, location: beforeStart, length: selection.location - beforeStart)

        let afterStart = selection.location + selection.length
        let afterLength = max(0, min(maxAfter, total == Int.max ? maxAfter : total - afterStart))
        let after = string(of: element, location: afterStart, length: afterLength)

        // Both reads failing means the element doesn't really support ranged
        // text (despite advertising a selected range) — no context.
        guard before != nil || after != nil else {
            NSLog("[Dictator] Context capture: element doesn't answer ranged text reads — no context.")
            return (nil, "this field doesn't answer text reads")
        }

        if requireFieldAccurate,
           !rangedReadsLookFieldAccurate(element, before: before ?? "", after: after ?? "") {
            NSLog("[Dictator] Context capture: ranged reads don't match the focused element's own value — not field-accurate.")
            return (nil, "this field's text coordinates are unreliable")
        }

        var documentTerms: [String] = []
        if mineTerms {
            let wideBeforeStart = max(0, selection.location - mineBeforeCap)
            let wideBefore = string(of: element, location: wideBeforeStart, length: selection.location - wideBeforeStart) ?? ""
            let wideAfterLength = max(0, min(mineAfterCap, total == Int.max ? mineAfterCap : total - afterStart))
            let wideAfter = string(of: element, location: afterStart, length: wideAfterLength) ?? ""
            documentTerms = DocumentTerms.distinctiveTerms(in: wideBefore + "\n" + wideAfter)
        }

        // Counts only — never the captured text. The unified log is not the
        // place for the user's document content.
        NSLog("[Dictator] Context capture: %d chars before / %d chars after caret (selection length %d, %d document terms).",
              before?.count ?? 0, after?.count ?? 0, selection.length, documentTerms.count)
        return (InsertionContext(textBefore: before ?? "", textAfter: after ?? "", documentTerms: documentTerms), nil)
    }

    /// Whether the ranged reads describe the focused field itself, as opposed
    /// to some larger container. Chromium answers `kAXSelectedTextRange` /
    /// `kAXStringForRange` in *page* coordinates when focus sits in a
    /// contenteditable editor (browser comment boxes, chat inputs), so "text
    /// before the caret" comes back as surrounding page prose even when the
    /// input itself is empty — and the join then prepends a spurious leading
    /// space to avoid "gluing onto" a word that isn't actually next to the
    /// caret. Cross-check against the element's own `kAXValue`: text that
    /// genuinely surrounds the caret must appear in the field's value. The
    /// first/last character of each read is dropped before the containment
    /// check so a cap boundary that split a grapheme can't cause a false
    /// mismatch. Elements that expose no string value can't be verified —
    /// trust only the classic per-field text roles there.
    private static func rangedReadsLookFieldAccurate(_ element: AXUIElement, before: String, after: String) -> Bool {
        var valueRef: CFTypeRef?
        let valueErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        if valueErr == .success, let value = valueRef as? String {
            let beforeNeedle = String(before.dropFirst())
            let afterNeedle = String(after.dropLast())
            if !beforeNeedle.isEmpty, !value.contains(beforeNeedle) { return false }
            if !afterNeedle.isEmpty, !value.contains(afterNeedle) { return false }
            return true
        }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        return role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
    }

    /// `kAXStringForRange` — the primitive that reads a substring without
    /// pulling the whole document value. Returns nil on AX errors, "" for an
    /// empty (but valid) range.
    private static func string(of element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &out
        )
        guard err == .success, let s = out as? String else { return nil }
        return s
    }
}
