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

private struct SoundThemeCard: View {
    let theme: SoundTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var envelope: [Float] = []

    private static let imageRadius: CGFloat = 8
    private static let ringInset: CGFloat = 4

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                waveform
                    .frame(height: 44)
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
        .task { envelope = await SoundThemeEnvelopes.envelope(for: theme) }
    }

    /// Peak envelope of the theme's start cue as a row of bars: the honest
    /// picture of how long and how sharp the set is.
    private var waveform: some View {
        Canvas { ctx, size in
            guard !envelope.isEmpty else { return }
            let n = envelope.count
            let inset: CGFloat = 8
            let gap: CGFloat = 1.5
            let barW = max(1, (size.width - 2 * inset - gap * CGFloat(n - 1)) / CGFloat(n))
            let maxH = size.height - 12
            let tint = selected ? Color.brandBlue : Color.secondary.opacity(0.7)
            for (i, v) in envelope.enumerated() {
                let h = max(1.5, CGFloat(v) * maxH)
                let rect = CGRect(x: inset + CGFloat(i) * (barW + gap), y: size.height / 2 - h / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(tint))
            }
        }
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

/// Renders each theme's start-cue envelope once, off the main thread, and
/// keeps it for the session — five renders of a few milliseconds each, but
/// not worth repeating every time the pane opens. Main-actor state (the
/// cards' `.task` runs there), so the cache needs no lock; only the render
/// itself hops off.
@MainActor
private enum SoundThemeEnvelopes {
    private static var cache: [SoundTheme: [Float]] = [:]

    static func envelope(for theme: SoundTheme) async -> [Float] {
        if let hit = cache[theme] { return hit }
        let env = await Task.detached(priority: .utility) {
            SoundSynth.envelope(.start, theme: theme, bins: 28)
        }.value
        cache[theme] = env
        return env
    }
}
