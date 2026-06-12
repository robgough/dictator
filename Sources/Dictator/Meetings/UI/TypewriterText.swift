import SwiftUI

/// Text that streams toward its `target` LLM-style: new content appears a
/// word at a time (fast — the cadence people now read as "the model is
/// talking"), and when the target REVISES something already shown, the
/// divergent tail visibly deletes word-by-word before the replacement
/// types in — the "rethinking" effect.
///
/// Mechanics: each target change cancels the in-flight animator and starts
/// one Task that (1) deletes back to the common prefix, (2) appends the
/// remainder word-by-word, publishing `displayed` as it goes. A trailing
/// block cursor shows while streaming. Styling (font/colour) is the
/// caller's, applied via environment as with any Text.
///
/// Guards: the first appearance jumps straight to the target (no replaying
/// a whole meeting), as do revisions far from the tail (the live
/// transcript's head-trim rotates thousands of characters off the front —
/// deleting and retyping them would be slapstick) and Reduce Motion.
struct TypewriterText: View {
    let target: String
    /// While true and not actively streaming, a chat-style cycling ellipsis
    /// trails the last word — "still listening, more coming" — so the pane
    /// never reads as stalled between utterances.
    var showsListeningDots = false
    /// Fired on every published step — the live pane uses it to keep the
    /// scroll pinned to the bottom while words land.
    var onTick: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed = ""
    @State private var streaming = false
    @State private var animator: Task<Void, Never>?
    @State private var dotPhase = 0

    private static let deleteStep: Duration = .milliseconds(14)
    private static let typeStep: Duration = .milliseconds(26)
    /// Revisions this far from the tail jump instead of animating.
    private static let maxAnimatedDeletion = 400
    private static let maxAnimatedAddition = 1600

    var body: some View {
        Text(displayed + suffix)
            .onChange(of: target) { _, new in retarget(to: new) }
            .onAppear { displayed = target }
            .onDisappear {
                animator?.cancel()
                streaming = false
            }
            .task(id: showsListeningDots && !reduceMotion) {
                guard showsListeningDots, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(450))
                    dotPhase = (dotPhase + 1) % 4
                }
            }
    }

    private var suffix: String {
        if streaming { return "▍" }
        guard showsListeningDots else { return "" }
        if reduceMotion { return " …" }
        return " " + String(repeating: ".", count: dotPhase)
    }

    private func retarget(to new: String) {
        animator?.cancel()
        guard !reduceMotion else {
            displayed = new
            streaming = false
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
                displayed = String(chars.prefix(max(cut, commonCount)))
                onTick?()
                try? await Task.sleep(for: Self.deleteStep)
            }
            guard !Task.isCancelled else { return }

            // Stream the new words in.
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
                shown = next
                displayed = String(newChars.prefix(shown))
                onTick?()
                try? await Task.sleep(for: Self.typeStep)
            }
        }
    }
}
