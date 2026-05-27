import SwiftUI

/// Settings → Meetings tab. Carries the per-Mac storage retention
/// settings, the cross-Mac summary preferences, and a short note about
/// speaker identification.
struct MeetingsPane: View {
    @Environment(AppState.self) private var state
    @State private var showSummaryPromptSheet = false

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("Delete audio after", selection: Binding(
                    get: { s.settings.meetingAudioRetentionDays },
                    set: { s.settings.meetingAudioRetentionDays = $0; state.save() }
                )) {
                    Text("Keep forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.menu)

                Picker("Delete entire meeting after", selection: Binding(
                    get: { s.settings.meetingAutoDeleteAfterDays },
                    set: { s.settings.meetingAutoDeleteAfterDays = $0; state.save() }
                )) {
                    Text("Keep forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Storage")
            } footer: {
                Text("Meeting audio is large — roughly 800 MB per hour combined across both tracks — but transcripts are tiny. \"Delete audio\" prunes the .caf files but keeps the transcript so you can still search and re-read older meetings without paying for the audio. \"Delete entire meeting\" drops everything including the transcript. Both sweeps run when the Meetings window opens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Echo cancellation", selection: Binding(
                    get: { s.settings.meetingMicEchoCancellation },
                    set: { s.settings.meetingMicEchoCancellation = $0; state.save() }
                )) {
                    ForEach(MeetingMicEchoCancellation.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Microphone")
            } footer: {
                Text("On a video call without headphones, your Mac's speakers play the remote audio and the mic picks it back up — so every remote utterance appears twice in the transcript, once correctly on the system track and once incorrectly tagged as you. Echo cancellation lets macOS subtract the playback signal from the mic capture before recording, so the bleed never makes it to disk. Automatic turns it on when the active output looks like speakers (built-in / external monitor) and off when it looks like headphones (AirPods, USB headset).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Summarise meetings automatically", isOn: Binding(
                    get: { s.settings.meetingSummaryEnabled },
                    set: { s.settings.meetingSummaryEnabled = $0; state.save() }
                ))
                Picker("Default summary style", selection: Binding(
                    get: { s.settings.defaultMeetingType },
                    set: { s.settings.defaultMeetingType = $0; state.save() }
                )) {
                    ForEach(MeetingType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    showSummaryPromptSheet = true
                } label: {
                    Label("Customise summary prompt…", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Summary")
            } footer: {
                Text("Runs the LLM you've picked in Settings → Models over the transcript after each meeting, extracting decisions, action items, and a short narrative. The default style biases the summary toward the structure people expect for that meeting type — stand-ups get per-person updates, retrospectives get what-went-well buckets, and so on. Auto-detect lets the model decide from the transcript. You can override the style for any individual meeting on its page via Summarise as ▾.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Your microphone is always tagged as you. The other side of the call is split into per-speaker turns once the diarization model has been downloaded (Settings → Models → Diarization). Click a speaker name on any meeting to rename them or change their colour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speakers")
            }

            Section {
                Toggle("Drop echoes captured by my microphone", isOn: Binding(
                    get: { s.settings.meetingDedupeMicEchoes },
                    set: { s.settings.meetingDedupeMicEchoes = $0; state.save() }
                ))
            } header: {
                Text("Echo cleanup")
            } footer: {
                Text("When you're not wearing headphones, your mic picks up the remote speakers and the same words appear twice in the transcript. This drops the mic-track copies. Turn off if you suspect it's eating legitimate overlapping speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showSummaryPromptSheet) {
            SummaryPromptSheet(isPresented: $showSummaryPromptSheet)
        }
    }
}

/// Sheet wrapper around `PromptCustomiser` for the meeting summary prompt.
/// Same shape as the Assistant prompt tab uses, just inside a modal sheet
/// because the Meetings tab is already a Form and we don't want to swap
/// the entire layout for one prompt field.
private struct SummaryPromptSheet: View {
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Meeting summary prompt")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            PromptCustomiser(
                description: "Used when Dictator summarises a meeting. The model is asked for strict JSON with decisions, action items, and a 3–6 sentence narrative.",
                builtin: DictatorSettings.builtinMeetingSummaryPrompt,
                addendum: $s.settings.meetingSummaryPromptAddendum,
                override: $s.settings.meetingSummaryPromptOverride
            ) { state.save() }
            .padding()
        }
        .frame(width: 720, height: 560)
    }
}
