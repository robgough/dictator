import Foundation
import CoreGraphics

/// Pure decision logic for "is the text the accessibility API just handed us
/// actually *before* the caret, or is it the field's greyed-out placeholder?"
///
/// Browsers (Chromium/Electron, Gecko) expose an empty editor's CSS-generated
/// placeholder — Quill's `data-placeholder`, Signal's "Message", LinkedIn's
/// "What do you want to talk about?" — as real text in the field's AXValue, on
/// the caret's own line. A ranged read then reports "Message" as the text
/// before the caret of an *empty* compose box, and `InsertionJoiner` duly
/// prepends a space and lowercases the first word as if the user were
/// continuing a sentence. This is the guard that spots that case.
///
/// Three independent signals, tried in order, each failing safe (change
/// nothing) when the app doesn't answer:
///
/// 1. **Attribute** — `AXPlaceholderValue`, when the app bothers to expose it.
///    Exact, but plenty of web editors don't publish it: Quill uses a
///    `data-placeholder` attribute plus a CSS `::before` pseudo-element, not
///    `aria-placeholder`, so Signal answers `noValue` here.
/// 2. **Character geometry** — where the characters actually are on screen. A
///    caret that genuinely follows a character sits at that character's
///    *trailing* edge; an overlaid placeholder is painted *under* the caret, so
///    the caret's rect starts at or before the "previous" character's leading
///    edge. Works in AppKit and in atomic web inputs — but Chromium refuses
///    `AXBoundsForRange` outright on a *contenteditable*
///    (`browser_accessibility_cocoa.mm`'s `frameForRange:` returns
///    `CGRectNull` unless the node `IsText()` or `IsAtomicTextField()`), which
///    is exactly the case we care most about.
/// 3. **Sibling overlay** — the route that actually catches Chromium. An empty
///    contenteditable exposes two direct children with identical full-width
///    frames: the `::before` placeholder block, and the empty `<p>` the caret
///    is in. Two sibling blocks in a real document never overlap — stacked
///    paragraphs are vertically disjoint, adjacent inline boxes merely touch —
///    so a pair of overlapping siblings, one of which holds exactly the text
///    we read "before" the caret, is a placeholder painted over the caret's
///    own paragraph. Every element answers `AXPosition`/`AXSize` even when
///    character bounds are refused, which is what makes this one work.
///
/// Kept free of any AX dependency so it can be exercised standalone (see
/// `scratch/placeholder-check/`); the AX reads themselves live in
/// `AXContextReader`.
enum PlaceholderDetection {
    /// Drops a trailing placeholder string from the text read before the caret.
    /// Whitespace-tolerant on the right (the placeholder is usually the whole
    /// line, but a stray newline/space can trail it). Returns `before`
    /// unchanged when there's no placeholder, it's blank, or it isn't the
    /// suffix — i.e. the check fails safe in every ambiguous case.
    nonisolated static func stripPlaceholderSuffix(_ before: String, placeholder: String?) -> String {
        guard let placeholder else { return before }
        let needle = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return before }
        let trimmed = trimmingTrailingWhitespace(before)
        guard trimmed.hasSuffix(needle) else { return before }
        return trimmingTrailingWhitespace(String(trimmed.dropLast(needle.count)))
    }

    /// Whether the caret is painted *on top of* the character reported as
    /// preceding it — the signature of an overlaid placeholder rather than
    /// real preceding text.
    ///
    /// Demands all three of: two usable rects, vertical overlap (same visual
    /// line), and a caret whose left edge is left of the previous character's
    /// midpoint. A caret that really follows a character sits at that
    /// character's `maxX`; an overlaid one sits at or before its `minX`, so the
    /// midpoint is a wide, unambiguous threshold. Anything degenerate → false.
    nonisolated static func caretSitsOnOverlay(previousChar: CGRect, caret: CGRect) -> Bool {
        guard isUsableRect(previousChar), isUsableRect(caret) else { return false }
        // Same line: the two rects have to share vertical extent.
        guard previousChar.minY < caret.maxY, caret.minY < previousChar.maxY else { return false }
        return caret.minX < previousChar.midX
    }

    // MARK: - Sibling overlay

    /// Longest text we'll entertain as a placeholder. Placeholders are short
    /// single lines ("Message", "What do you want to talk about?"); a real
    /// paragraph of preceding prose is not this case.
    static let maxPlaceholderLength = 120

    /// Cheap pre-conditions for the sibling-overlay check, so it costs nothing
    /// (not even the child reads) in ordinary documents. All of: the read
    /// starts at the very beginning of the field, is non-empty, is one short
    /// line, and ends in a non-space character — if it ended in whitespace the
    /// joiner wouldn't add a leading space anyway, so there'd be nothing to fix.
    nonisolated static func siblingOverlayGateOpen(before: String, startsAtFieldStart: Bool) -> Bool {
        guard startsAtFieldStart else { return false }
        guard !before.isEmpty, before.count <= maxPlaceholderLength else { return false }
        guard !before.contains(where: { $0.isNewline }) else { return false }
        guard let last = before.last, !last.isWhitespace else { return false }
        return true
    }

    /// One direct child of the text area, reduced to what the decision needs:
    /// the child's own frame, and — when a bounded descendant search found a
    /// static text whose value matches the text read before the caret — that
    /// text's frame. `matchingTextFrame` being non-nil is what marks a child as
    /// the placeholder candidate; `.null` is the "found it, but its frame was
    /// unreadable" sentinel (which then declines to overlap, i.e. fails safe).
    struct BlockCandidate: Equatable, Sendable {
        let frame: CGRect
        let matchingTextFrame: CGRect?

        init(frame: CGRect, matchingTextFrame: CGRect? = nil) {
            self.frame = frame
            self.matchingTextFrame = matchingTextFrame
        }

        var holdsMatchingText: Bool { matchingTextFrame != nil }

        /// The frame to reason with: the child's own, or the matching text's
        /// when the child's is degenerate (Gecko wraps nothing — the text leaf
        /// *is* the child — and some nodes answer position but not size).
        var usableFrame: CGRect? {
            if isUsableRect(frame) { return frame }
            if let matchingTextFrame, isUsableRect(matchingTextFrame) { return matchingTextFrame }
            return nil
        }
    }

    /// The verdict. `firstTwo` describes the field's first two children (the
    /// only ones examined — an empty editor with a placeholder has exactly
    /// two); `childCount` is how many children it actually has, so a real
    /// document full of paragraphs is refused before any of this matters.
    ///
    /// One of the two children must hold the text we read before the caret;
    /// the other is the caret's own block. Overlapping frames → placeholder.
    nonisolated static func placeholderOverlay(firstTwo: [BlockCandidate], childCount: Int) -> Bool {
        guard (2...4).contains(childCount), firstTwo.count == 2 else { return false }
        let candidateIndex: Int
        if firstTwo[0].holdsMatchingText {
            candidateIndex = 0
        } else if firstTwo[1].holdsMatchingText {
            candidateIndex = 1
        } else {
            return false // neither child is the text we read — not this shape
        }
        guard let candidate = firstTwo[candidateIndex].usableFrame,
              let caretBlock = firstTwo[1 - candidateIndex].usableFrame else { return false }
        return blocksOverlap(candidate, caretBlock)
    }

    /// Whether two sibling blocks genuinely overlap, as opposed to touching at
    /// an edge. The 2-point slack on each axis absorbs sub-pixel frame maths
    /// and the hairline overlaps adjacent inline boxes sometimes report.
    nonisolated static func blocksOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        guard isUsableRect(a), isUsableRect(b) else { return false }
        let shared = a.intersection(b)
        guard !shared.isNull, isUsableRect(shared) else { return false }
        return shared.width > 2 && shared.height > 2
    }

    /// A rect we're willing to reason about: real numbers, positive extent.
    /// Apps answer `AXBoundsForRange` with zeroes, nulls and infinities for
    /// off-screen, collapsed or unsupported ranges.
    nonisolated static func isUsableRect(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return false }
        return rect.size.width > 0 && rect.size.height > 0
    }

    private nonisolated static func trimmingTrailingWhitespace(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}
