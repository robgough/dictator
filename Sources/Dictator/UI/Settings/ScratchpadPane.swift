import SwiftUI
import AppKit
import KeyboardShortcuts

/// Scratchpad settings.
///
/// Lifted out of General and given its own sidebar section: it's a distinct
/// feature with its own hotkey and its own window, and it was competing for
/// attention inside a pane that's otherwise about app-wide plumbing.
struct ScratchpadPane: View {
    @Environment(AppState.self) private var state

    /// The display the size preview describes. Held in state rather than
    /// computed inline so it can be refreshed when the Settings window is
    /// dragged to another screen — `NSScreen` reads aren't observable.
    @State private var previewScreen: NSScreen?

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Toggle("Scratchpad", isOn: $s.settings.scratchpadEnabled)
                    .onChange(of: s.settings.scratchpadEnabled) { _, _ in state.save() }
                if s.settings.scratchpadEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleScratchpad)
                        Button("Reset") {
                            KeyboardShortcuts.reset(.toggleScratchpad)
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Scratchpad")
            } footer: {
                SectionFootnote("A floating note on a shortcut, saved to your synced folder.")
            }

            if s.settings.scratchpadEnabled {
                Section {
                    sizePreviews(width: s.settings.scratchpadWidth)

                    Picker("Width", selection: $s.settings.scratchpadWidth) {
                        ForEach(ScratchpadWidth.allCases) { width in
                            Text(width.label).tag(width)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: s.settings.scratchpadWidth) { _, _ in
                        state.save()
                        state.scratchpadController?.relayoutIfVisible()
                    }
                } header: {
                    Text("Size")
                } footer: {
                    // Not `SectionFootnote`: that takes a LocalizedStringKey,
                    // and this sentence is computed from the attached displays.
                    Text(sizeFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear { refreshScreen() }
        // The Settings window can be dragged between displays while this pane
        // is open, and the drawing is only honest about the screen it's on.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            refreshScreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreen()
        }
    }

    /// The drawing of this screen, plus a row of reference Macs.
    ///
    /// A percentage of your own display answers "how big is Large *here*",
    /// which is the question you asked — but not "is Large a sensible choice",
    /// which needs something to compare against. The reference row is what
    /// turns one number into a sense of scale.
    @ViewBuilder
    private func sizePreviews(width: ScratchpadWidth) -> some View {
        VStack(spacing: 14) {
            DisplayPreview(width: width, display: currentDisplay, height: 116, emphasised: true)

            let others = ReferenceDisplay.commonMacs.filter { !$0.matchesWidth(of: currentDisplay) }
            if !others.isEmpty {
                VStack(spacing: 6) {
                    Text("For comparison")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(others) { reference in
                            DisplayPreview(width: width, display: reference, height: 58, emphasised: false)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// This Mac's screen as a `ReferenceDisplay`, so the hero and the
    /// comparison thumbnails go through exactly the same drawing and the same
    /// arithmetic.
    private var currentDisplay: ReferenceDisplay {
        guard let screen = previewScreen, screen.visibleFrame.width > 0 else {
            return ReferenceDisplay(name: "This display", pointWidth: 1512, pointHeight: 982)
        }
        let frame = screen.visibleFrame
        return ReferenceDisplay(
            name: NSScreen.screens.count > 1 ? screen.localizedName : "This display",
            pointWidth: frame.width,
            pointHeight: frame.height
        )
    }

    /// The screen this Settings window is on — the one the user is looking
    /// at. Falls back to the main display when the window isn't placed yet.
    private func refreshScreen() {
        previewScreen = NSApp.keyWindow?.screen
            ?? NSApp.windows.first(where: { $0.isVisible && $0.screen != nil })?.screen
            ?? NSScreen.main
    }

    /// One sentence of fact under the drawings. The percentages are on the
    /// drawings themselves, so this covers what a picture can't: how the card
    /// is positioned, which screen it opens on, and what the reference sizes
    /// actually are.
    private var sizeFootnote: String {
        var sentence = "The card is full height, pinned to the right"
        sentence += NSScreen.screens.count > 1
            ? " of whichever screen your pointer is on."
            : "."
        if state.settings.scratchpadWidth.points > currentDisplay.usableWidth {
            sentence += " \(state.settings.scratchpadWidth.label) is wider than this display, so it's capped to fit."
        }
        sentence += " Comparison sizes are those Macs at their default resolution."
        return sentence
    }
}

/// A display to draw the Scratchpad on: this Mac's screen, or a well-known
/// Mac used as a yardstick.
///
/// Reference sizes are the *default* scaled resolution each machine ships
/// with (the "Looks like" setting), not the native panel resolution — that's
/// the point space windows are actually laid out in, so it's the one that
/// makes the card's share of the screen come out right.
struct ReferenceDisplay: Identifiable {
    let name: String
    let pointWidth: CGFloat
    let pointHeight: CGFloat

    var id: String { "\(name)-\(Int(pointWidth))x\(Int(pointHeight))" }

    static let commonMacs: [ReferenceDisplay] = [
        ReferenceDisplay(name: "14\u{2033} MacBook Pro", pointWidth: 1512, pointHeight: 982),
        ReferenceDisplay(name: "16\u{2033} MacBook Pro", pointWidth: 1728, pointHeight: 1117),
        ReferenceDisplay(name: "Studio Display", pointWidth: 2560, pointHeight: 1440),
    ]

    var usableWidth: CGFloat { pointWidth }

    var aspect: CGFloat {
        pointHeight > 0 ? pointWidth / pointHeight : 16.0 / 10.0
    }

    /// The card's real width here — the same clamp `ScratchpadController`
    /// applies, kept in step with it.
    func cardWidth(_ width: ScratchpadWidth) -> CGFloat {
        let margin: CGFloat = 16
        return min(CGFloat(width.points), max(0, pointWidth - margin * 2))
    }

    /// Share of the display the card covers, 0–1.
    func fraction(_ width: ScratchpadWidth) -> CGFloat {
        guard pointWidth > 0 else { return 0.3 }
        return max(0.03, min(1, cardWidth(width) / pointWidth))
    }

    func percent(_ width: ScratchpadWidth) -> Int {
        Int((fraction(width) * 100).rounded())
    }

    /// Whether this is effectively the same width as `other`, so the
    /// comparison row can drop a reference that duplicates the user's own
    /// screen rather than showing the same picture twice.
    func matchesWidth(of other: ReferenceDisplay) -> Bool {
        abs(pointWidth - other.pointWidth) < 40
    }
}

/// A scale drawing of how much of a screen the card covers.
///
/// A width in points is meaningless without knowing the display it lands on,
/// and the four names don't help either — the only honest answer to "how big
/// is Large?" is a picture of it. Drawn at the display's real aspect ratio,
/// with the card at its real proportion, on the same illustrated desktop the
/// HUD picker uses (`MiniDesktop`) so the two read as pictures of the same
/// Mac.
private struct DisplayPreview: View {
    let width: ScratchpadWidth
    let display: ReferenceDisplay
    /// Height of the screen drawing; the width follows from the aspect ratio.
    let height: CGFloat
    /// The user's own screen gets the full treatment; the comparison
    /// thumbnails are quieter so they don't compete with it.
    let emphasised: Bool

    private var radius: CGFloat { emphasised ? 8 : 5 }

    var body: some View {
        VStack(spacing: 5) {
            Canvas(rendersAsynchronously: false) { ctx, size in
                MiniDesktop.draw(&ctx, size: size)

                // The card: full height with its edge margin, pinned right —
                // exactly how `ScratchpadController` lays it out.
                let margin = 0.018 * size.width
                let cardWidth = max(3, size.width * display.fraction(width) - margin)
                let card = CGRect(
                    x: size.width - cardWidth - margin,
                    y: margin,
                    width: cardWidth,
                    height: size.height - margin * 2
                )
                ctx.fill(
                    Path(roundedRect: card, cornerRadius: 0.02 * size.width),
                    with: .color(Color.orange.opacity(0.92))
                )
                // A few "lines of note" so it reads as the Scratchpad rather
                // than an orange bar. Skipped on the thumbnails, where they'd
                // be sub-pixel smudges.
                guard size.height > 80 else { return }
                let inset = card.width * 0.12
                let lineWidths: [CGFloat] = [0.9, 0.7, 0.8]
                for (i, fraction) in lineWidths.enumerated() {
                    let lineWidth = (card.width - inset * 2) * fraction
                    guard lineWidth > 2 else { break }
                    let y = card.minY + card.height * 0.16 + CGFloat(i) * card.height * 0.11
                    ctx.fill(
                        Path(roundedRect: CGRect(x: card.minX + inset, y: y,
                                                 width: lineWidth,
                                                 height: max(1, card.height * 0.035)),
                             cornerRadius: 1),
                        with: .color(.white.opacity(0.55))
                    )
                }
            }
            .frame(width: height * display.aspect, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(emphasised ? 0.12 : 0.10), lineWidth: 1)
            )

            VStack(spacing: 1) {
                Text(display.name)
                    .font(.system(size: emphasised ? 11 : 10, weight: emphasised ? .semibold : .regular))
                    .foregroundStyle(emphasised ? .primary : .secondary)
                    .lineLimit(1)
                Text("\(Int(display.cardWidth(width))) pt \u{00B7} \(display.percent(width))%")
                    .font(.system(size: emphasised ? 10 : 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(display.name): the Scratchpad is \(Int(display.cardWidth(width))) points wide, about \(display.percent(width)) percent of the screen")
    }
}
