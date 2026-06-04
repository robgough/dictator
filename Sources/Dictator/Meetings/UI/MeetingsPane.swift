import SwiftUI

/// Settings → Meetings tab. Hosts the preview notice and the master
/// opt-in toggle at the top (Meetings ships as an early preview, off by
/// default), then the per-Mac storage retention settings, the cross-Mac
/// summary preferences, and a short note about speaker identification.
/// Everything below the toggle is greyed out until the preview is enabled;
/// the notice stays visible even when it's on.
struct MeetingsPane: View {
    @Environment(AppState.self) private var state
    @State private var showSummaryPromptSheet = false

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "testtube.2")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("Meetings is an early preview")
                            .font(.headline)
                    }
                    Text("Record a call, get a transcript split by speaker, and have notes written for you — all on-device. It's early days and we're not yet sure how reliable it is, so expect rough edges. You're very welcome to play with it; feedback (good or bad) is hugely appreciated at hello@robgough.net.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: Binding(
                        get: { s.settings.meetingsEnabled },
                        set: { s.settings.meetingsEnabled = $0; state.save() }
                    )) {
                        Text("Enable Meetings")
                            .font(.body.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.large)
                }
                .padding(.vertical, 4)
            } footer: {
                if !s.settings.meetingsEnabled {
                    Text("While Meetings is off, the menu bar entries stay hidden and the settings below are disabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
            .disabled(!s.settings.meetingsEnabled)

            Section {
                Toggle("Write notes automatically", isOn: Binding(
                    get: { s.settings.meetingSummaryEnabled },
                    set: { s.settings.meetingSummaryEnabled = $0; state.save() }
                ))
                Toggle("Show a live transcript while recording", isOn: Binding(
                    get: { s.settings.meetingLiveTranscriptEnabled },
                    set: { s.settings.meetingLiveTranscriptEnabled = $0; state.save() }
                ))
                Toggle("Build a first pass while recording", isOn: Binding(
                    get: { s.settings.meetingLiveNotesEnabled },
                    set: { s.settings.meetingLiveNotesEnabled = $0; state.save() }
                ))
                .disabled(!s.settings.meetingLiveTranscriptEnabled)
                .padding(.leading, 18)
                Toggle("Correct live notes as the conversation moves on", isOn: Binding(
                    get: { s.settings.meetingLiveNotesSelfCorrectEnabled },
                    set: { s.settings.meetingLiveNotesSelfCorrectEnabled = $0; state.save() }
                ))
                .disabled(!s.settings.meetingLiveTranscriptEnabled || !s.settings.meetingLiveNotesEnabled)
                .padding(.leading, 36)
                Picker("Default notes style", selection: Binding(
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
                    Label("Customise notes prompt…", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Notes")
            } footer: {
                Text("Runs the LLM you've picked in Settings → Models over the transcript after each meeting and writes markdown notes — a summary, the key discussion points, decisions, and action items. The default style biases the notes toward the structure people expect for that meeting type — stand-ups get per-person updates, retrospectives get what-went-well buckets, and so on. Auto-detect lets the model decide from the transcript. You can override the style for any individual meeting on its page via Re-run ▾. \"Show a live transcript\" displays a running draft of the conversation as you record; turning it off skips that work entirely, which lightens the load on long calls (the full transcript is still produced after the meeting ends). \"Build a first pass while recording\" quietly drafts notes live during the call (it runs the LLM on the GPU, so it uses more battery) — it builds on the live transcript, so it needs that switched on; the full notes are rewritten when the meeting ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!s.settings.meetingsEnabled)

            Section {
                Text("Your microphone is always tagged as you. The other side of the call is split into per-speaker turns once the diarization model has been downloaded (Settings → Models → Diarization). Click a speaker name on any meeting to rename them or change their colour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speakers")
            }
            .disabled(!s.settings.meetingsEnabled)

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
            .disabled(!s.settings.meetingsEnabled)
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
                Text("Meeting notes prompt")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            PromptCustomiser(
                description: "Used when Dictator writes notes for a meeting. The model is asked for markdown with a summary, key discussion points, decisions, and action items.",
                builtin: DictatorSettings.builtinMeetingSummaryPrompt,
                addendum: $s.settings.meetingSummaryPromptAddendum,
                override: $s.settings.meetingSummaryPromptOverride
            ) { state.save() }
            .padding()
        }
        .frame(width: 720, height: 560)
    }
}
