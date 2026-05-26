import SwiftUI

/// Settings → Meetings tab. v0.1 ships with a single setting: the
/// auto-delete window. The pane is sized as a placeholder for the
/// summary toggle + diarization model controls that land in v0.2/0.3.
struct MeetingsPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("Auto-delete after", selection: Binding(
                    get: { s.settings.meetingAutoDeleteAfterDays },
                    set: { s.settings.meetingAutoDeleteAfterDays = $0; state.save() }
                )) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Storage")
            } footer: {
                Text("Meeting audio and transcripts live under ~/Library/Application Support/Dictator/Meetings. Each meeting's two audio files weigh roughly 80 MB per hour combined. Set a window and Dictator prunes older meetings the next time the Meetings window opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Diarization and summarisation are coming in the next releases. For v0.1, microphone audio is labelled \"Me\" and the system audio is labelled \"Other\" wholesale.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Coming soon")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
