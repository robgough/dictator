import AppKit
import SwiftUI

/// Word-by-word animated transcript for the realtime dictation preview.
///
/// The dictation engine re-transcribes the WHOLE audio buffer roughly every
/// 700 ms, so on each snapshot most words are unchanged while a handful at the
/// live edge get revised. Rendering one flat string meant every snapshot
/// hard-cut the changed words and, whenever a word's width changed, shoved the
/// rest of the line sideways — the "jumpy/jittery" feel.
///
/// Here each word is its own identified view in a wrapping flow, so SwiftUI can
/// animate every adjustment individually:
///   • a word that survives a snapshot keeps its identity and SLIDES to its new
///     position when the line reflows (it never flashes),
///   • a word that's replaced cross-fades — the old one fades out fast while the
///     new one fades in,
///   • a freshly-spoken word fades in at the end.
/// Only what actually changed moves, so the bulk of the text sits still.
///
/// Owns its text colour; callers style the font (it's read from the
/// environment by the inner word views).
struct StreamingTranscript: View {
    let target: String
    var baseColor: NSColor = .secondaryLabelColor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tokens: [Token] = []
    @State private var nextID = 0
    @State private var cursorOn = true

    private struct Token: Identifiable, Equatable {
        let id: Int
        var text: String
    }

    /// Old fades out fast so the slot clears; new fades in a touch slower so it
    /// reads as settling rather than snapping. Survivors slide on a gentle
    /// spring when the line reflows.
    private static let appear = AnyTransition.opacity.animation(.easeOut(duration: 0.22))
    private static let vanish = AnyTransition.opacity.animation(.easeIn(duration: 0.12))
    private static let reflow = Animation.spring(response: 0.32, dampingFraction: 0.9)

    var body: some View {
        WordFlow(spacingX: 3.5, lineSpacing: 2) {
            ForEach(tokens) { token in
                Text(token.text)
                    .foregroundStyle(Color(nsColor: baseColor))
                    .transition(.asymmetric(insertion: Self.appear, removal: Self.vanish))
            }
            // Trailing block cursor doubles as the "listening" placeholder
            // before any words land. Blinked via alpha so it never changes the
            // layout. Steady (not blinking) under Reduce Motion.
            Text("\u{258D}")
                .foregroundStyle(Color(nsColor: baseColor).opacity(cursorOn ? 0.8 : 0.0))
        }
        .onAppear {
            tokens = Self.tokenize(target, from: 0)
            nextID = tokens.count
        }
        .onChange(of: target) { _, new in retarget(to: new) }
        .task(id: reduceMotion) {
            guard !reduceMotion else { cursorOn = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                cursorOn.toggle()
            }
        }
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    private static func tokenize(_ s: String, from startID: Int) -> [Token] {
        words(s).enumerated().map { Token(id: startID + $0.offset, text: $0.element) }
    }

    private func retarget(to new: String) {
        let newWords = Self.words(new)
        let oldWords = tokens.map(\.text)

        guard !reduceMotion else {
            tokens = Self.tokenize(new, from: nextID)
            nextID += newWords.count
            return
        }

        // The unchanged head and tail keep their tokens — and thus their
        // identity, so they only ever slide. Everything between is the churn:
        // re-id it so the old words fade out and the new ones fade in.
        var p = 0
        while p < newWords.count, p < oldWords.count, newWords[p] == oldWords[p] { p += 1 }
        var s = 0
        while s < newWords.count - p, s < oldWords.count - p,
              newWords[newWords.count - 1 - s] == oldWords[oldWords.count - 1 - s] { s += 1 }

        var result: [Token] = []
        result.append(contentsOf: tokens.prefix(p))
        for w in newWords[p..<(newWords.count - s)] {
            result.append(Token(id: nextID, text: w))
            nextID += 1
        }
        result.append(contentsOf: tokens.suffix(s))

        withAnimation(Self.reflow) {
            tokens = result
        }
    }
}

/// Minimal left-to-right wrapping layout — one slot per word, wrapping to the
/// next line when the next word won't fit. Because it reports its final size
/// immediately (only subview *positions* animate), the enclosing ScrollView can
/// pin the bottom correctly while words slide into place.
private struct WordFlow: Layout {
    var spacingX: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacingX
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x)
        }
        let width = proposal.width ?? widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            sub.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacingX
            lineHeight = max(lineHeight, size.height)
        }
    }
}
