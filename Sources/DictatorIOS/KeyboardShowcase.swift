import SwiftUI

/// Standalone keyboard mockup used only for App Store screenshots.
///
/// The real Dictator keyboard is an app-extension binary that only
/// shows up inside other apps after the user enables it in Settings →
/// Keyboards. We can't drive that automatically in the iOS Simulator
/// without a long setup dance (provision the extension, switch into
/// Notes, switch keyboards). For the App Store screenshot, the next
/// best thing is a faithful pixel-accurate mockup of how the keyboard
/// looks in-context — a faux compose surface up top, the keyboard
/// down below.
///
/// Gated behind the `DICTATOR_SCREENSHOT_STATE=keyboard` env var so
/// only the UI test ever surfaces it.
struct KeyboardShowcase: View {
    var body: some View {
        VStack(spacing: 0) {
            // Faux "Notes" compose area to convey context — the
            // keyboard otherwise floats with no anchor and confuses
            // viewers about where the buttons get used.
            VStack(alignment: .leading, spacing: 8) {
                Text("Mum's birthday")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Saturday 14th — book the table at the new place on Elm, six of us, ask about the garden side.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                Text("|")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            Spacer()
            keyboardMockup
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var keyboardMockup: some View {
        VStack(spacing: 12) {
            // Always-on Paste pill — Paste button on the left, preview
            // of what's on the clipboard on the right (Dictator puts a
            // snapshot in the App Group whenever it auto-copies, so
            // the keyboard can preview without ever reading the
            // pasteboard string itself).
            pasteRow

            // Primary action tiles — compact horizontal pills, not
            // the big circular buttons the keyboard used to have.
            HStack(spacing: 12) {
                primary(tint: .red, icon: "mic.fill", label: "Dictate")
                primary(tint: .purple, icon: "wand.and.stars", label: "Assist")
            }

            // Secondary row — no extra horizontal padding here so it
            // aligns with the buttons above.
            HStack(spacing: 10) {
                secondary(icon: "arrow.uturn.backward", label: "Undo")
                Text("space")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                secondary(icon: "return", label: "Return")
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 60, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
            }

            // "Globe" hint mimicking the system keyboard-switcher row.
            HStack {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    /// Paste button + preview pill, matching `KeyboardRootView.pasteChip`.
    /// Both render at cornerRadius 14 to share a shape family with the
    /// primary tiles.
    private var pasteRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.caption.weight(.semibold))
                Text("Paste")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor)
            )

            HStack(spacing: 6) {
                Text("Pick up flowers on the way home, will swing by the place on Elm.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· 14 words")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Compact tile matching `KeyboardRootView.primaryButton`. Icon +
    /// label on a 56pt-tall coloured rounded rectangle.
    private func primary(tint: Color, icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint)
        )
    }

    private func secondary(icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 60, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .accessibilityLabel(label)
    }
}
