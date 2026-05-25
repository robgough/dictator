import SwiftUI
import UIKit

/// Step-by-step instructions for enabling the Dictator keyboard.
/// iOS makes this deliberately fiddly for third-party keyboards
/// (the Allow Full Access toggle in particular has a confirmation
/// dialog), so users genuinely benefit from a visual walkthrough.
///
/// Presented as a sheet from the dismissible helper card on the
/// main view. Dismissing the sheet doesn't dismiss the card —
/// that's a separate persistent flag.
struct KeyboardSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(alignment: .leading, spacing: 16) {
                        step(1, title: "Open the iOS Settings app",
                             body: "It's the silver gear icon on your home screen.")
                        step(2, title: "Tap General → Keyboard",
                             body: "Then tap Keyboards (the inner menu).")
                        step(3, title: "Tap Add New Keyboard…",
                             body: "Choose Dictator from the list of third-party keyboards.")
                        step(4, title: "Tap the Dictator row again",
                             body: "Now turn on Allow Full Access. Confirm the dialog — it lets the keyboard talk to the host app to record and transcribe.")
                        step(5, title: "Switch to Dictator in any app",
                             body: "Tap into a text field. Hold the globe key (bottom-left) on the system keyboard and pick Dictator.")
                    }
                    .padding(.horizontal, 4)

                    Button {
                        openSettings()
                    } label: {
                        Label("Open Settings", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)

                    privacyFooter
                }
                .padding(20)
            }
            .navigationTitle("Enable the Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Type with your voice anywhere")
                    .font(.title3.weight(.semibold))
            }
            Text("The Dictator keyboard lets you tap a button in any app's text field to dictate or transform text — your recording flows through to Dictator, and the result comes back to the field you were typing in.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Why Allow Full Access?", systemImage: "lock.shield")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("iOS keyboards can't access the microphone directly. Full Access lets the Dictator keyboard open the Dictator app, which does the recording on-device. Nothing leaves your device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Opens the iOS Settings app at the Dictator app's privacy /
    /// settings root. iOS 16+ resolves `openSettingsURLString` to
    /// the per-app settings; on older versions it falls back to the
    /// Settings root, which is still useful.
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
