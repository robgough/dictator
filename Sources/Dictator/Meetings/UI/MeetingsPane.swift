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
    @State private var showingSetsEditor = false
    @State private var showingPeopleEditor = false
    @State private var typeEditor: MeetingTypeEditorMode?

    var body: some View {
        @Bindable var s = state
        // Nil when a usable LLM is configured. A missing LLM disables the
        // whole feature (toggle included) — the notes pass is the product.
        let llmMessage = MeetingsFeature.llmRequirementMessage
        let effectivelyEnabled = s.settings.meetingsEnabled && llmMessage == nil
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
                    if let llmMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(llmMessage)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Toggle(isOn: Binding(
                        get: { s.settings.meetingsEnabled },
                        set: { s.settings.meetingsEnabled = $0; state.save() }
                    )) {
                        Text("Enable Meetings")
                            .font(.body.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .disabled(llmMessage != nil)
                }
                .padding(.vertical, 4)
            } footer: {
                if !effectivelyEnabled {
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
            .disabled(!effectivelyEnabled)

            Section {
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
                    ForEach(MeetingTypeRegistry.all(settings: s.settings)) { def in
                        Text(def.displayName).tag(def.meetingTypeID)
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
                Text("Meetings write their notes with \(ModelCatalog.meetingsRequiredLLMName) — it's the only model that does it reliably, so it must be the selected model in Settings → Models before you record or import. Notes aren't written automatically: when a meeting finishes you get the transcript, and you press Generate on the meeting's page once you've checked who said what — now, or whenever's convenient. The default style biases the notes toward the structure people expect for that meeting type — stand-ups get per-person updates, retrospectives get what-went-well buckets, and so on. Auto-detect lets the model decide from the transcript. You can override the style for any individual meeting on its page via Re-run ▾. \"Show a live transcript\" displays a running draft of the conversation as you record; turning it off skips that work entirely, which lightens the load on long calls (the full transcript is still produced after the meeting ends). \"Build a first pass while recording\" quietly drafts notes live during the call (it runs the LLM on the GPU, so it uses more battery) — it builds on the live transcript, so it needs that switched on, and the draft is kept until you generate the final notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!effectivelyEnabled)

            Section {
                Toggle("Coach your meetings", isOn: Binding(
                    get: { s.settings.meetingCoachEnabled },
                    set: { s.settings.meetingCoachEnabled = $0; state.save() }
                ))
                Toggle("Show the coach on the notch island", isOn: Binding(
                    get: { s.settings.meetingCoachChipEnabled },
                    set: { s.settings.meetingCoachChipEnabled = $0; state.save() }
                ))
                .disabled(!s.settings.meetingCoachEnabled)
                .padding(.leading, 18)
                Button {
                    showingSetsEditor = true
                } label: {
                    Label("Edit key point sets…", systemImage: "checklist")
                }
                .disabled(!s.settings.meetingCoachEnabled)
                Toggle("Match meetings to calendar events", isOn: Binding(
                    get: { s.settings.meetingCalendarMatchingEnabled },
                    set: { s.settings.meetingCalendarMatchingEnabled = $0; state.save() }
                ))
                Toggle("Recognise people across meetings", isOn: Binding(
                    get: { s.settings.peopleRecognitionEnabled },
                    set: { s.settings.peopleRecognitionEnabled = $0; state.save() }
                ))
                Button {
                    showingPeopleEditor = true
                } label: {
                    Label("Edit people…", systemImage: "person.2")
                }
            } header: {
                Text("Coach")
            } footer: {
                Text("The coach watches how you handle a meeting while it records: live talk balance and pace, occasional one-line nudges on the island (monologuing, interrupting, dominating), a key-points checklist it ticks off as the conversation covers them, and a private written report afterwards. Everything is computed on this Mac from the recording itself, is visible only to you — never in the meeting's notes or exports — and switching the coach off here removes all of it. \"Match meetings to calendar events\" asks for calendar access the first time and gives each recording its real title, attendees, and scheduled length (which also powers the coach's wrapping-up reminder); calendar data never leaves your Mac. \"Recognise people across meetings\" remembers each named speaker's voice on this Mac, so the same person is recognised and named automatically in future meetings — Edit people shows everything stored and lets you forget anyone, voice included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!effectivelyEnabled)

            Section {
                Toggle("Capture shared screens", isOn: Binding(
                    get: { s.settings.meetingCaptureScreenshots },
                    set: { s.settings.meetingCaptureScreenshots = $0; state.save() }
                ))
            } header: {
                Text("Shared screens")
            } footer: {
                Text("Captures still frames of shared content during a meeting — slides, demos, whatever's on the call window — and keeps only the ones that change, as images in the meeting's folder. Capture is scoped to the meeting window only: your other windows, notifications, and second screen are never seen. This needs macOS Screen Recording permission (the system shows a purple capture indicator while recording, and you'll be asked to grant it the first time — capture begins from the next meeting after that). Frames stay on this Mac and are deleted with the meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!effectivelyEnabled)

            Section {
                ForEach(MeetingTypeRegistry.builtIns) { def in
                    typeRow(def)
                }
                ForEach(s.settings.customMeetingTypes) { def in
                    typeRow(def)
                }
                Button {
                    typeEditor = .create(seed: nil)
                } label: {
                    Label("New style…", systemImage: "plus")
                }
            } header: {
                Text("Note styles")
            } footer: {
                Text("Each style is a template: ALL-CAPS lines name the sections the notes should have, and the text under each header tells the model what belongs there. Built-in styles can't be edited, but Duplicate gives you an editable copy to start from. Deleting a style is safe — meetings that used it keep their notes, and re-running them just falls back to the generic style.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!effectivelyEnabled)

            Section {
                Text("Your microphone is always tagged as you. The other side of the call is split into per-speaker turns once the diarization model has been downloaded (Settings → Models → Diarization). Click a speaker name on any meeting to rename them or change their colour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speakers")
            }
            .disabled(!effectivelyEnabled)

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
            .disabled(!effectivelyEnabled)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // The LLM-requirement notice reads ModelManager's download states —
        // refresh on entry so a model downloaded since the last look (or
        // removed behind our back) is reflected immediately.
        .onAppear { ModelManager.shared.refreshCachedStates() }
        .sheet(isPresented: $showingSetsEditor) {
            CoachSetsEditor()
        }
        .sheet(isPresented: $showingPeopleEditor) {
            PeopleEditor()
        }
        .sheet(isPresented: $showSummaryPromptSheet) {
            SummaryPromptSheet(isPresented: $showSummaryPromptSheet)
        }
        .sheet(item: $typeEditor) { mode in
            MeetingTypeEditorSheet(mode: mode) { source in
                typeEditor = .create(seed: source)
            }
        }
    }

    /// One row in the Note styles list — name + description, with the
    /// actions that fit the type: built-ins are viewable and duplicable,
    /// customs editable and deletable. Deleting a style that's still set
    /// as the default falls the default back to Auto-detect.
    @ViewBuilder
    private func typeRow(_ def: MeetingTypeDefinition) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(def.displayName)
                if !def.detail.isEmpty {
                    Text(def.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if def.isBuiltIn {
                Button("View") { typeEditor = .view(def) }
                    .controlSize(.small)
                Button {
                    typeEditor = .create(seed: def)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .controlSize(.small)
                .help("Duplicate this style as an editable copy.")
            } else {
                Button("Edit") { typeEditor = .edit(def) }
                    .controlSize(.small)
                Button(role: .destructive) {
                    deleteType(def)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Delete this style. Meetings that used it keep their notes.")
            }
        }
    }

    private func deleteType(_ def: MeetingTypeDefinition) {
        state.settings.customMeetingTypes.removeAll { $0.id == def.id }
        if state.settings.defaultMeetingType == def.meetingTypeID {
            state.settings.defaultMeetingType = .auto
        }
        state.save()
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
