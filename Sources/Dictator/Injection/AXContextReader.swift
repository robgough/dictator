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
    ///
    /// `placeholderChars` reports how much greyed-out placeholder text the
    /// capture discarded (see `PlaceholderDetection`); 0 in the normal case.
    /// Diagnostics only — the returned context already has it removed.
    static func captureDetailed(maxBefore: Int, maxAfter: Int, mineTerms: Bool = false,
                                requireFieldAccurate: Bool = false)
        -> (context: InsertionContext?, reason: String?, placeholderChars: Int)
    {
        guard AXIsProcessTrusted() else {
            NSLog("[Dictator] Context capture: no Accessibility permission.")
            return (nil, "Accessibility permission is off", 0)
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else {
            NSLog("[Dictator] Context capture: no focused element (AXError %d).", err.rawValue)
            return (nil, "no focused text field", 0)
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
            return (nil, "focused on Dictator, not your app", 0)
        }

        // Never read password fields. (They expose a masked/empty value by
        // design, but we don't even ask.)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == (kAXSecureTextFieldSubrole as String) {
            NSLog("[Dictator] Context capture: focused element is a secure field — skipped.")
            return (nil, "a password field", 0)
        }

        // No role allowlist beyond the secure-field exclusion: text fields,
        // text areas, combo boxes, and WebKit's AXWebArea all answer the
        // ranged reads below, and anything that can't simply fails them —
        // which collapses to the same nil as "no context available".
        var rangeRef: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard rangeErr == .success, let rangeValue = rangeRef else {
            NSLog("[Dictator] Context capture: focused element has no selected-text range (AXError %d) — no context.", rangeErr.rawValue)
            return (nil, "this field exposes no text cursor", 0)
        }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection),
              selection.location >= 0 else {
            NSLog("[Dictator] Context capture: selected-text range undecodable or negative — no context.")
            return (nil, "this field exposes no text cursor", 0)
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
            return (nil, "this field exposes no text cursor", 0)
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
            return (nil, "this field doesn't answer text reads", 0)
        }

        if requireFieldAccurate,
           !rangedReadsLookFieldAccurate(element, before: before ?? "", after: after ?? "") {
            NSLog("[Dictator] Context capture: ranged reads don't match the focused element's own value — not field-accurate.")
            return (nil, "this field's text coordinates are unreliable", 0)
        }

        // Placeholder guard. An empty browser editor (Signal's compose box,
        // Quill-based web composers in Firefox) exposes its greyed-out
        // placeholder as real text on the caret's line, so the reads above
        // report "Message" as the text *before* the caret of an empty field —
        // which the joiner would treat as a sentence to continue. The
        // field-accuracy cross-check above can't catch it: the placeholder
        // genuinely is in the element's AXValue. See `PlaceholderDetection`.
        var beforeText = before ?? ""
        let placeholder = placeholderValue(of: element)
        var placeholderChars = 0
        if !beforeText.isEmpty {
            let stripped = PlaceholderDetection.stripPlaceholderSuffix(beforeText, placeholder: placeholder)
            if stripped.count != beforeText.count {
                placeholderChars = beforeText.count - stripped.count
                beforeText = stripped
                NSLog("[Dictator] Context capture: dropped %d chars of placeholder text before the caret (attribute).",
                      placeholderChars)
            } else if caretSitsOnPlaceholderOverlay(element, caretLocation: selection.location,
                                                    hasTextAfter: !(after ?? "").isEmpty) {
                placeholderChars = beforeText.count
                beforeText = ""
                NSLog("[Dictator] Context capture: dropped %d chars of placeholder text before the caret (geometry).",
                      placeholderChars)
            } else if PlaceholderDetection.siblingOverlayGateOpen(
                          before: beforeText,
                          startsAtFieldStart: beforeStart == 0 && selection.location == beforeText.count),
                      siblingBlockOverlaysCaret(element, before: beforeText) {
                placeholderChars = beforeText.count
                beforeText = ""
                NSLog("[Dictator] Context capture: dropped %d chars of placeholder text before the caret (sibling overlay).",
                      placeholderChars)
            }
        }

        var documentTerms: [String] = []
        if mineTerms {
            let wideBeforeStart = max(0, selection.location - mineBeforeCap)
            let wideBeforeRead = string(of: element, location: wideBeforeStart, length: selection.location - wideBeforeStart) ?? ""
            // Same placeholder trim on the mining sweep — the placeholder is
            // the field's chrome, not the user's vocabulary. Suffix-only here:
            // the geometric verdict says nothing about the 16 k characters of
            // genuine document that precede it.
            let wideBefore = PlaceholderDetection.stripPlaceholderSuffix(wideBeforeRead, placeholder: placeholder)
            let wideAfterLength = max(0, min(mineAfterCap, total == Int.max ? mineAfterCap : total - afterStart))
            let wideAfter = string(of: element, location: afterStart, length: wideAfterLength) ?? ""
            documentTerms = DocumentTerms.distinctiveTerms(in: wideBefore + "\n" + wideAfter)
        }

        // Counts only — never the captured text. The unified log is not the
        // place for the user's document content.
        NSLog("[Dictator] Context capture: %d chars before / %d chars after caret (selection length %d, %d document terms, %d placeholder chars dropped).",
              beforeText.count, after?.count ?? 0, selection.length, documentTerms.count, placeholderChars)
        return (InsertionContext(textBefore: beforeText, textAfter: after ?? "", documentTerms: documentTerms),
                nil, placeholderChars)
    }

    /// `AXPlaceholderValue` — the field's own declaration of its greyed-out
    /// prompt text, when it publishes one. nil for anything non-string, empty,
    /// or unsupported.
    private static func placeholderValue(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &ref)
        guard err == .success, let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    /// The general (attribute-free) placeholder test: ask where the last
    /// "preceding" character and the caret are actually drawn. Chromium and
    /// Gecko paint the placeholder *under* the caret rather than before it, so
    /// the caret's rect lands on top of the character the ranged read claims it
    /// follows. Fails safe — any unsupported attribute, AX error or degenerate
    /// rect returns false and nothing is dropped.
    private static func caretSitsOnPlaceholderOverlay(_ element: AXUIElement,
                                                      caretLocation: Int,
                                                      hasTextAfter: Bool) -> Bool {
        guard caretLocation > 0 else { return false }
        guard let previous = boundsForRange(of: element, location: caretLocation - 1, length: 1),
              PlaceholderDetection.isUsableRect(previous) else { return false }
        // A caret with text after it has a character to measure; at the very
        // end of the field only the zero-length range exists. Either can come
        // back collapsed, so try the other before giving up.
        let primaryLength = hasTextAfter ? 1 : 0
        var caret = boundsForRange(of: element, location: caretLocation, length: primaryLength)
        if caret == nil || !PlaceholderDetection.isUsableRect(caret!) {
            caret = boundsForRange(of: element, location: caretLocation, length: primaryLength == 1 ? 0 : 1)
        }
        guard let caret, PlaceholderDetection.isUsableRect(caret) else { return false }
        return PlaceholderDetection.caretSitsOnOverlay(previousChar: previous, caret: caret)
    }

    /// The route that catches Chromium contenteditables, where both checks
    /// above are structurally dead: `AXPlaceholderValue` is `noValue` (Quill
    /// draws its placeholder with a CSS `::before`), and `AXBoundsForRange`
    /// returns a null rect for every range because a contenteditable is not an
    /// *atomic* text field. What the element does expose is its children: an
    /// empty editor has the `::before` placeholder block and the empty `<p>`
    /// holding the caret, sitting on top of each other with identical frames.
    /// Real siblings — stacked paragraphs, adjacent inline boxes — never do.
    ///
    /// Strictly bounded: one children read, at most four frame reads, and a
    /// 12-read budget for the descendant text search, so a wedged app can't
    /// stall delivery (every read also inherits the element's messaging
    /// timeout). Called only when `siblingOverlayGateOpen` says the read looks
    /// like a placeholder in the first place.
    private static func siblingBlockOverlaysCaret(_ element: AXUIElement, before: String) -> Bool {
        guard let children = childElements(of: element), (2...4).contains(children.count) else { return false }
        let needle = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        var budget = 12
        let firstTwo = children.prefix(2).map { child in
            PlaceholderDetection.BlockCandidate(
                frame: frame(of: child) ?? .null,
                matchingTextFrame: matchingStaticTextFrame(in: child, needle: needle, depth: 0, budget: &budget)
            )
        }
        return PlaceholderDetection.placeholderOverlay(firstTwo: Array(firstTwo), childCount: children.count)
    }

    /// Bounded depth-first hunt for a static text whose value is exactly the
    /// text we read before the caret. The element itself counts (Gecko exposes
    /// `::before` content as a text leaf directly under the editor; Chromium
    /// wraps it in an `AXGroup`, so it's a grandchild). Returns that text's
    /// frame, or `.null` when it matched but its frame was unreadable — the
    /// caller treats `.null` as "found, but can't be trusted to overlap".
    private static func matchingStaticTextFrame(in element: AXUIElement, needle: String,
                                                depth: Int, budget: inout Int) -> CGRect? {
        guard depth <= 3, budget > 0 else { return nil }
        budget -= 1
        if stringAttribute(element, kAXRoleAttribute as String) == (kAXStaticTextRole as String) {
            guard let value = stringAttribute(element, kAXValueAttribute as String),
                  value.trimmingCharacters(in: .whitespacesAndNewlines) == needle else { return nil }
            return frame(of: element) ?? .null
        }
        guard let kids = childElements(of: element) else { return nil }
        for kid in kids.prefix(4) {
            if let hit = matchingStaticTextFrame(in: kid, needle: needle, depth: depth + 1, budget: &budget) {
                return hit
            }
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFArrayGetTypeID(),
              let children = ref as? [AXUIElement] else { return nil }
        return children
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// Screen frame of any element, from `AXPosition` + `AXSize`. These are
    /// answered even by nodes that refuse character-level bounds.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let value = axValue(element, kAXPositionAttribute as String, of: .cgPoint),
              let sizeValue = axValue(element, kAXSizeAttribute as String, of: .cgSize) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Reads an attribute expected to be an `AXValue` of a given type, checking
    /// both the CF type and the AXValue type before the caller decodes it.
    private static func axValue(_ element: AXUIElement, _ attribute: String, of type: AXValueType) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = ref as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        return value
    }

    /// `kAXBoundsForRange` — screen rect of a character range. Returns nil on
    /// AX errors or a value that isn't a `CGRect`.
    private static func boundsForRange(of element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0, length >= 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &out
        )
        guard err == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        let value = out as! AXValue
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
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
