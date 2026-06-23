import AppKit
import SwiftUI

/// Text that streams toward its `target` LLM-style: new content appears a
/// word at a time (fast — the cadence people now read as "the model is
/// talking"), each word FADING in over a quarter second so the tail of the
/// stream visibly brightens, and when the target REVISES something already
/// shown, the divergent tail deletes word-by-word before the replacement
/// types in — the "rethinking" effect.
///
/// Mechanics: each target change cancels the in-flight animator and starts
/// one Task that (1) deletes back to the common prefix, (2) appends the
/// remainder word-by-word, recording each word's appearance time. Rendering
/// goes through a TimelineView (30 fps, paused whenever no fade is active)
/// that paints recent words with age-proportional alpha. A trailing block
/// cursor shows while streaming; a chat-style cycling ellipsis shows
/// between utterances while `showsListeningDots`.
///
/// Owns its text colour (the per-word alpha is an attribute override on the
/// base colour) — callers style the font only.
///
/// Guards: the first appearance jumps straight to the target (no replaying
/// a whole meeting), as do revisions far from the tail (the live
/// transcript's head-trim rotates thousands of characters off the front —
/// deleting and retyping them would be slapstick) and Reduce Motion.
struct TypewriterText: View {
    /// What trails the text while idle (not actively streaming).
    enum IdleIndicator {
        case none
        /// A blinking block cursor — the native "ready, listening" idiom.
        /// Blinked via alpha on the cursor glyph, never by removing it, so
        /// the layout doesn't shift each phase.
        case blinkingCursor
    }

    let target: String
    var idleIndicator: IdleIndicator = .none
    var baseColor: NSColor = .secondaryLabelColor
    /// Fired on every published step — the live pane uses it to keep the
    /// scroll pinned to the bottom while words land.
    var onTick: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = ""
    @State private var streaming = false
    @State private var animator: Task<Void, Never>?
    @State private var cursorOn = true
    /// Character ranges of recently-typed words and when each appeared —
    /// the fade set. Cleared shortly after streaming settles.
    @State private var fades: [FadeEntry] = []

    private struct FadeEntry: Equatable {
        let start: Int
        let end: Int
        let at: Date
    }

    private static let deleteStep: Duration = .milliseconds(14)
    private static let typeStep: Duration = .milliseconds(26)
    /// Quick but noticeable — at the type cadence this keeps the trailing
    /// ~9 words mid-fade, a comet of brightening text behind the cursor.
    private static let fadeDuration: TimeInterval = 0.25
    /// Revisions this far from the tail jump instead of animating.
    private static let maxAnimatedDeletion = 400
    private static let maxAnimatedAddition = 1600

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: fades.isEmpty)) { timeline in
            streamedText(at: timeline.date)
        }
        .onChange(of: target) { _, new in retarget(to: new) }
        .onAppear { displayed = target }
        .onDisappear {
            animator?.cancel()
            streaming = false
            fades = []
        }
        .task(id: idleIndicator == .blinkingCursor && !reduceMotion) {
            guard idleIndicator == .blinkingCursor, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                cursorOn.toggle()
            }
        }
    }

    private var showsCursor: Bool {
        streaming || idleIndicator == .blinkingCursor
    }

    /// Compose the rendered line as a *stable head* (`Text` of a plain String —
    /// no per-glyph attributes, so SwiftUI lays it out cheaply and can reuse it
    /// across frames) plus a *short fading tail*. The tail spans only the active
    /// fade set (≤24 recent words), so per-frame cost is O(tail), independent of
    /// transcript length.
    ///
    /// The previous version built an `AttributedString` over the entire
    /// `displayed` string (capped at ~12 k chars) and, for every fade, walked it
    /// from `startIndex` via `offsetByCharacters` — ≈48 × O(n) grapheme walks,
    /// *plus* a full O(n) AttributedString construction, every frame at 30 fps.
    /// That was a steady main-thread render tax that scaled with the live
    /// transcript and made the whole app (including the dictation HUD) stutter
    /// during long meetings.
    private func streamedText(at now: Date) -> Text {
        let count = displayed.count
        // Fades still brightening (alpha < 1). They always sit at the tail, so
        // the earliest active fade's start is where attributed rendering begins.
        let active = fades.filter {
            $0.start < count && now.timeIntervalSince($0.at) < Self.fadeDuration
        }
        let split = min(active.map(\.start).min() ?? count, count)
        let splitIdx = displayed.index(displayed.startIndex, offsetBy: split)

        // Head: everything settled to the base colour — one plain Text, no
        // per-character attributes.
        var text = Text(verbatim: String(displayed[..<splitIdx]))
            .foregroundColor(Color(nsColor: baseColor))

        // Tail: the short, still-brightening region. Indexing is relative to the
        // tail (a few hundred chars at most), never the whole string.
        if split < count {
            var tail = AttributedString(String(displayed[splitIdx...]))
            tail.foregroundColor = Color(nsColor: baseColor)
            for fade in active {
                let alpha = min(1, max(0, now.timeIntervalSince(fade.at) / Self.fadeDuration))
                guard alpha < 1 else { continue }
                let s = tail.index(tail.startIndex, offsetByCharacters: fade.start - split)
                let e = tail.index(tail.startIndex, offsetByCharacters: min(fade.end, count) - split)
                tail[s..<e].foregroundColor = Color(nsColor: baseColor.withAlphaComponent(alpha))
            }
            text = text + Text(tail)
        }

        if showsCursor {
            // Solid while typing; alpha-blinked while idle (the glyph stays in
            // layout either way). Reduce Motion: steady and dim.
            let alpha: CGFloat = streaming ? 1 : (reduceMotion ? 0.4 : (cursorOn ? 0.85 : 0))
            text = text + Text(verbatim: "▍")
                .foregroundColor(Color(nsColor: baseColor.withAlphaComponent(alpha)))
        }
        return text
    }

    private func retarget(to new: String) {
        animator?.cancel()
        guard !reduceMotion else {
            displayed = new
            streaming = false
            fades = []
            return
        }
        let newChars = Array(new)
        let oldChars = Array(displayed)
        var common = 0
        while common < newChars.count, common < oldChars.count, newChars[common] == oldChars[common] {
            common += 1
        }
        guard oldChars.count - common <= Self.maxAnimatedDeletion,
              newChars.count - common <= Self.maxAnimatedAddition else {
            displayed = new
            streaming = false
            fades = []
            return
        }

        let commonCount = common
        animator = Task { @MainActor in
            streaming = true
            defer { streaming = false }

            // Delete the divergent tail, word by word.
            while !Task.isCancelled, displayed.count > commonCount {
                let chars = Array(displayed)
                var cut = chars.count - 1
                while cut > commonCount, chars[cut - 1] != " ", chars[cut - 1] != "\n" {
                    cut -= 1
                }
                // Eat the separator too so each step removes a whole word.
                while cut > commonCount, cut > 0, chars[cut - 1] == " " || chars[cut - 1] == "\n" {
                    cut -= 1
                }
                let kept = max(cut, commonCount)
                displayed = String(chars.prefix(kept))
                fades.removeAll { $0.start >= kept }
                onTick?()
                try? await Task.sleep(for: Self.deleteStep)
            }
            guard !Task.isCancelled else { return }

            // Stream the new words in, each entering the fade set.
            var shown = commonCount
            displayed = String(newChars.prefix(shown))
            while !Task.isCancelled, shown < newChars.count {
                var next = shown
                // Include leading separators with the word they precede.
                while next < newChars.count, newChars[next] == " " || newChars[next] == "\n" {
                    next += 1
                }
                while next < newChars.count, newChars[next] != " ", newChars[next] != "\n" {
                    next += 1
                }
                fades.append(FadeEntry(start: shown, end: next, at: Date()))
                if fades.count > 24 { fades.removeFirst(fades.count - 24) }
                shown = next
                displayed = String(newChars.prefix(shown))
                onTick?()
                try? await Task.sleep(for: Self.typeStep)
            }
            guard !Task.isCancelled else { return }

            // Let the last words finish brightening, then clear the fade set
            // so the TimelineView pauses.
            try? await Task.sleep(for: .milliseconds(Int(Self.fadeDuration * 1000) + 60))
            if !Task.isCancelled { fades = [] }
        }
    }
}
