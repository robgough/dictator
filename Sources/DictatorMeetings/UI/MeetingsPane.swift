import SwiftUI

/// Settings → Meetings tab: how meetings behave — live transcript / first
/// pass, the coach, shared-screen capture, note styles, echo cleanup, and the
/// notes-prompt customiser.
///
/// The "Enable Meetings" master toggle and the LLM-requirement gate that
/// wrapped this pane in the single-app era are gone: installing this app IS
/// the opt-in, and "which model writes the notes" now lives on the Providers
/// tab, which can say something far more useful than "off".
struct MeetingsPane: View {
    @Environment(MeetingsAppState.self) private var state
    @State private var showSummaryPromptSheet = false
    @State private var showingSetsEditor = false
    @State private var showingPeopleEditor = false
    @State private var typeEditor: MeetingTypeEditorMode?

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Toggle("Show a live transcript while recording", isOn: Binding(
                    get: { s.settings.meetingLiveTranscriptEnabled },
                    set: { s.settings.meetingLiveTranscriptEnabled = $0; state.save() }
                ))
                .help("Shows a running draft of the conversation as you record. Turning it off skips that work on long calls; the full transcript is still produced after the meeting ends.")
                Toggle("Build a first pass while recording", isOn: Binding(
                    get: { s.settings.meetingLiveNotesEnabled },
                    set: { s.settings.meetingLiveNotesEnabled = $0; state.save() }
                ))
                .disabled(!s.settings.meetingLiveTranscriptEnabled)
                .padding(.leading, 18)
                .help("Quietly drafts notes live during the call (runs the LLM on the GPU, so more battery). Builds on the live transcript, so that must be on; the draft is kept until you generate the final notes.")
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
                SectionFootnote("Notes are written by your selected MLX formatting model (Settings → Models) — capable models only; the smallest are off here and Apple's on-device model is too small. Tuned for \(ModelCatalog.meetingsRecommendedLLMName); others work but can be weaker on long calls. Notes aren't automatic: after a meeting, check who said what and press Generate. The default style shapes the notes — Auto-detect lets the model decide; override per meeting via Re-run ▾.")
            }

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
                .help("Asks for calendar access the first time, then gives each recording its real title, attendees, and scheduled length (which powers the coach's wrapping-up reminder). Calendar data never leaves your Mac.")
                Toggle("Recognise people across meetings", isOn: Binding(
                    get: { s.settings.peopleRecognitionEnabled },
                    set: { s.settings.peopleRecognitionEnabled = $0; state.save() }
                ))
                .help("Remembers each named speaker's voice on this Mac, so the same person is recognised and named automatically in future meetings. Edit people shows everything stored and lets you forget anyone, voice included.")
                Button {
                    showingPeopleEditor = true
                } label: {
                    Label("Edit people…", systemImage: "person.2")
                }
            } header: {
                Text("Coach")
            } footer: {
                SectionFootnote("The coach watches how you run a meeting — live talk balance and pace, occasional one-line nudges on the island, a key-points checklist, and a private written report afterwards. Computed on this Mac and visible only to you (never in the notes or exports); turning the coach off removes all of it.")
            }

            Section {
                Toggle("Capture shared screens automatically", isOn: Binding(
                    get: { s.settings.meetingCaptureScreenshots },
                    set: { s.settings.meetingCaptureScreenshots = $0; state.save() }
                ))
            } header: {
                Text("Shared screens")
            } footer: {
                SectionFootnote("Captures still frames of shared content — slides, demos — keeping only the ones that change, as images in the meeting's folder. Scoped to the meeting window only; your other windows and screens are never seen. Needs Screen Recording permission (a purple indicator shows while running); you can also toggle capture per meeting from the Shared screen panel. Frames stay on this Mac and are deleted with the meeting.")
            }

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
                SectionFootnote("Each style is a template: ALL-CAPS lines name the sections, and the text under each tells the model what belongs there. Built-in styles can't be edited, but Duplicate makes an editable copy. Deleting a style is safe — meetings that used it keep their notes.")
            }

            Section {
                Text("Your microphone is always tagged as you. The other side of the call is split into per-speaker turns once the diarization model is downloaded (Settings → Models → Diarization). Click a speaker name on any meeting to rename them or change their colour.")
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
                SectionFootnote("When you're not wearing headphones, your mic picks up the remote speakers and the same words appear twice. This drops the mic-track copies. Turn off if you suspect it's eating legitimate overlapping speech.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
    @Environment(MeetingsAppState.self) private var state
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
                builtin: MeetingsSettings.builtinMeetingSummaryPrompt,
                addendum: $s.settings.meetingSummaryPromptAddendum,
                override: $s.settings.meetingSummaryPromptOverride
            ) { state.save() }
            .padding()
        }
        .frame(width: 720, height: 560)
    }
}
