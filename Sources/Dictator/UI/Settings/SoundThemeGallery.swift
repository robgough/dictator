import SwiftUI

/// The cue-set picker: a card per `SoundTheme`, each with a little waveform
/// of its start cue and a play button that samples the whole set (arm,
/// start, stop, done). Click the card to choose. Same shape as
/// `HUDStyleGallery` so the two sections read as a pair.
struct SoundThemeGallery: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SoundTheme.allCases) { theme in
                SoundThemeCard(theme: theme, selected: state.settings.soundTheme == theme) {
                    guard state.settings.soundTheme != theme else { return }
                    state.settings.soundTheme = theme
                    state.save()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct SoundThemeCard: View {
    let theme: SoundTheme
    let selected: Bool
    let action: () -> Void
    let envelope: [Float]
    @State private var hovering = false

    private static let imageRadius: CGFloat = 8
    private static let ringInset: CGFloat = 4
    private static let waveHeight: CGFloat = 44
    private static let barMaxHeight: CGFloat = 32

    init(theme: SoundTheme, selected: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.selected = selected
        self.action = action
        self.envelope = SoundThemeEnvelopes.envelope(for: theme)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                waveform
                    .frame(height: Self.waveHeight)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: Self.imageRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.imageRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        playButton.padding(4)
                    }
                    .padding(Self.ringInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.imageRadius + Self.ringInset, style: .continuous)
                            .strokeBorder(Color.brandBlue, lineWidth: 2)
                            .opacity(selected ? 1 : 0)
                    )
                    .scaleEffect(hovering && !selected ? 1.02 : 1)
                Text(theme.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(theme.detail)
        .accessibilityLabel(theme.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Peak envelope of the theme's start cue as a row of bars: the honest
    /// picture of how long and how sharp the set is. Plain shapes rather than
    /// a `Canvas` — a Canvas hosted in the AppKit settings shell doesn't
    /// always repaint when its data changes, so the cards sat blank until a
    /// hover forced a redraw.
    private var waveform: some View {
        HStack(spacing: 1.5) {
            ForEach(Array(envelope.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .fill(selected ? Color.brandBlue : Color.secondary.opacity(0.7))
                    .frame(height: max(1.5, CGFloat(value) * Self.barMaxHeight))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .accessibilityHidden(true)
    }

    private var playButton: some View {
        Button {
            SoundEffects.shared.preview(theme)
        } label: {
            Image(systemName: "play.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.brandBlue)
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(.plain)
        .help("Play a sample")
        .accessibilityLabel("Play a sample of \(theme.label)")
    }
}

/// Renders each theme's start-cue envelope once and keeps it for the session
/// — a couple of milliseconds per theme in a release build, and not worth
/// repeating every time the pane opens. Rendered synchronously on demand so a
/// card always has its bars on its very first draw; main-actor state, so the
/// cache needs no lock.
@MainActor
private enum SoundThemeEnvelopes {
    private static var cache: [SoundTheme: [Float]] = [:]

    static func envelope(for theme: SoundTheme) -> [Float] {
        if let hit = cache[theme] { return hit }
        let env = SoundSynth.envelope(.start, theme: theme, bins: 28)
        cache[theme] = env
        return env
    }
}
