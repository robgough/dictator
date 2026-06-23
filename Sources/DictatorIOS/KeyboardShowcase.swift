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
/// Mirrors `KeyboardRootView`'s Liquid Glass styling: every tile is a
/// `.glassEffect` rounded rect with a tinted glyph, not a solid colour
/// fill. Keep the two in sync — when the real keyboard's look changes,
/// this mockup has to follow or the screenshot drifts out of date.
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

            // Primary action tiles — glass faces with tinted glyphs,
            // matching `KeyboardRootView.primaryButton` (24pt gap, as in
            // its idle row).
            HStack(spacing: 24) {
                primary(tint: .red, icon: "mic.fill", label: "Dictate")
                primary(tint: .purple, icon: "wand.and.stars", label: "Assist")
            }

            // Secondary row — no extra horizontal padding here so it
            // aligns with the buttons above.
            HStack(spacing: 10) {
                secondary(icon: "arrow.uturn.backward", label: "Undo")
                Text("space")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                secondary(icon: "return", label: "Return")
                secondary(icon: "delete.left", label: "Backspace")
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
    /// Both render as glass at cornerRadius 10 + fixed 36pt height so they
    /// share the shape family of the secondary-row tiles below. The Paste
    /// glyph carries the accent tint (its enabled state) rather than a
    /// solid accent fill.
    private var pasteRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.caption.weight(.semibold))
                Text("Paste")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))

            HStack(spacing: 6) {
                Text("Pick up flowers on the way home, will swing by the place on Elm.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· 14 words")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
    }

    /// Compact tile matching `KeyboardRootView.primaryButton`: a glass
    /// face with a tinted icon + label, 56pt tall — not a solid colour
    /// fill with a white glyph.
    private func primary(tint: Color, icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.callout.weight(.semibold))
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    /// Icon-only glass tile matching `KeyboardRootView.secondaryButton`
    /// and `backspaceButton` — 60×44, cornerRadius 10.
    private func secondary(icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 60, height: 44)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .accessibilityLabel(label)
    }
}
