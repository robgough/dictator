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
            // Model readiness chip.
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Model loaded")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(.tertiarySystemBackground)))

            // Primary buttons.
            HStack(spacing: 24) {
                primary(tint: .red, icon: "mic.fill", label: "Dictate", enabled: true)
                primary(tint: .purple, icon: "wand.and.stars", label: "Assist", enabled: true)
            }

            Text("Tap a button — Dictator opens, you talk, the result lands here when you come back.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 2)

            // Secondary row.
            HStack(spacing: 10) {
                secondary(icon: "arrow.uturn.backward", label: "Undo", enabled: true)
                Text("space")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                secondary(icon: "return", label: "Return", enabled: true)
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 60, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            // "Globe" hint mimicking the system keyboard-switcher row.
            HStack {
                Image(systemName: "globe")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    private func primary(tint: Color, icon: String, label: String, enabled: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .opacity(enabled ? 1 : 0.4)
    }

    private func secondary(icon: String, label: String, enabled: Bool) -> some View {
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
