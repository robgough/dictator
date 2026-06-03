import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Renders the chronological speaker turns for a ready meeting. Per-speaker
/// colour bar on the leading edge. Plain `Text(.textSelection(.enabled))`
/// so copy works.
struct TranscriptView: View {
    @Environment(AppState.self) private var state
    let meta: MeetingMeta
    let transcript: MeetingTranscript?
    @Bindable var session: MeetingSession
    @State private var player = MeetingPlayer()
    @State private var hasAudio: Bool = false
    @State private var tab: Tab = .notes

    /// Notes are the primary surface; the rough live "raw" notes (when kept)
    /// and the transcript live behind the other tabs.
    enum Tab: Hashable { case notes, raw, transcript }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch tab {
            case .notes:
                NotesPanel(session: session, meta: meta, onSeek: seekFromNotes)
            case .raw:
                rawTab
            case .transcript:
                transcriptTab
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadAudio() }
        .onDisappear { player.unload() }
        .onChange(of: meta.id) { _, _ in
            loadAudio()
            if tab == .raw, !hasRawNotes { tab = .notes }
        }
        .background {
            // Keyboard shortcuts for the tab switch (hidden, zero-size).
            Button("") { tab = .notes }.keyboardShortcut("1", modifiers: .command)
            Button("") { tab = .transcript }.keyboardShortcut("2", modifiers: .command)
        }
    }

    /// Tab switcher + the document-level actions (copy / export / re-process).
    /// These live above both tabs so the primary verb — copy the notes as
    /// markdown — is always one click away.
    private var header: some View {
        HStack(spacing: 8) {
            Picker("View", selection: $tab) {
                Text("Transcript").tag(Tab.transcript)
                if hasRawNotes {
                    Text("Quick notes").tag(Tab.raw)
                }
                Text("Final notes").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if let md = currentTabCopyText {
                CopyButton(text: md, label: copyLabel)
                    .help("Copy the current view as Markdown.")
            }
            if let transcript {
                Button {
                    exportTranscript(transcript: transcript)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
            if hasAnyAudioOnDisk {
                Button {
                    Task {
                        await session.runProcessor(
                            parakeetModelID: state.settings.parakeetModelID
                        )
                    }
                } label: {
                    Label("Re-process", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Re-run the transcription and diarization pipeline from the recorded audio. Useful after a fix that improved transcript quality.")
                .disabled(session.state.isProcessing)
            }
        }
    }

    private var hasRawNotes: Bool {
        guard let raw = meta.rawNotes else { return false }
        return !raw.markdown.isEmpty
    }

    /// The rough notes captured live during the meeting, kept alongside the
    /// polished final notes. Read-only; selectable + copyable.
    @ViewBuilder
    private var rawTab: some View {
        if let raw = meta.rawNotes {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text("Quick notes").font(.headline)
                    Text("captured live").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                MarkdownNotesView(markdown: raw.markdown, speakers: meta.speakers, onSeek: seekFromNotes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .notesSurface()
                Text("Rough notes captured live as the meeting ran — kept because they're often more complete than the polished final notes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("No raw notes for this meeting.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Jump from a note's timestamp pill into the transcript + audio so the
    /// user can verify what was actually said.
    private func seekFromNotes(_ seconds: Double) {
        tab = .transcript
        guard hasAudio else { return }
        player.seek(to: seconds)
        if !player.isPlaying { player.togglePlayPause() }
    }

    @ViewBuilder
    private var transcriptTab: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    SpeakerCountChip(count: meta.speakers.count, suspicious: speakerCountLooksOff)
                    ForEach(meta.speakers, id: \.id) { speaker in
                        EditableSpeakerChip(speaker: speaker, session: session)
                    }
                    Spacer()
                }

                if hasAudio {
                    PlaybackBar(player: player)
                } else {
                    AudioMissingNote(
                        audioOnAnotherMac: meta.audioFiles.mic != nil || meta.audioFiles.system != nil
                    )
                }

                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    SegmentRow(
                        segment: segment,
                        meta: meta,
                        player: hasAudio ? player : nil
                    )
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No transcript yet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadAudio() {
        // The session's URL helpers gate on meta.audioFiles, so a meeting
        // whose audio has been pruned (auto-delete or manual) returns nil
        // for both. Player handles missing files defensively too.
        let micURL: URL? = meta.audioFiles.mic.map { _ in MeetingStorage.micURL(for: meta.id) }
        let sysURL: URL? = meta.audioFiles.system.map { _ in MeetingStorage.systemURL(for: meta.id) }
        hasAudio = player.load(micURL: micURL, systemURL: sysURL)
    }

    /// True when at least one audio track is still present on disk. Drives
    /// the Re-process button — pruned meetings can't be re-transcribed.
    private var hasAnyAudioOnDisk: Bool {
        let fm = FileManager.default
        let micPresent = meta.audioFiles.mic != nil
            && fm.fileExists(atPath: MeetingStorage.micURL(for: meta.id).path)
        let sysPresent = meta.audioFiles.system != nil
            && fm.fileExists(atPath: MeetingStorage.systemURL(for: meta.id).path)
        return micPresent || sysPresent
    }

    /// The whole meeting as Markdown — notes lead, transcript follows. This is
    /// the primary "give me something to paste into my notes app" payload.
    /// Falls back to a title + notes body when there's no transcript; nil when
    /// there's nothing to copy.
    /// Heuristic for an implausible diarization result, used to flag the
    /// speaker-count chip. Only an improbably HIGH count is flagged — a single
    /// speaker is perfectly normal (solo brainstorming, or recording a video
    /// you're watching), so we don't cry wolf on it.
    private var speakerCountLooksOff: Bool {
        meta.speakers.count >= 8
    }

    private var copyLabel: String {
        switch tab {
        case .notes: return "Copy notes"
        case .raw: return "Copy quick notes"
        case .transcript: return "Copy transcript"
        }
    }

    /// Markdown for the currently-selected tab, so Copy gives you exactly what
    /// you're looking at — notes, raw notes, or the transcript.
    private var currentTabCopyText: String? {
        switch tab {
        case .notes:
            if let notes = meta.notes { return "# \(meta.title)\n\n\(notes.markdown)" }
            if let transcript { return MeetingExporter.markdown(transcript: transcript, meta: meta) }
            return nil
        case .raw:
            if let raw = meta.rawNotes { return "# \(meta.title)\n\n\(raw.markdown)" }
            return nil
        case .transcript:
            guard let transcript, !transcript.segments.isEmpty else { return nil }
            return MeetingExporter.transcriptMarkdown(transcript: transcript, meta: meta)
        }
    }

    /// NSSavePanel-driven export. The picker's allowed types determine
    /// the on-disk format — plain text or markdown.
    private func exportTranscript(transcript: MeetingTranscript) {
        let panel = NSSavePanel()
        panel.title = "Export meeting"
        panel.message = "Choose where to save the transcript."
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md") ?? UTType.plainText]
        panel.canCreateDirectories = true
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).md"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isMarkdown = url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "markdown"
        let body = isMarkdown
            ? MeetingExporter.markdown(transcript: transcript, meta: meta)
            : MeetingExporter.plainText(transcript: transcript, meta: meta)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Dictator] Meeting export failed: \(error)")
        }
    }
}

private struct SegmentRow: View {
    let segment: MeetingTranscriptSegment
    let meta: MeetingMeta
    /// nil when the meeting's audio has been pruned — the timestamp
    /// still shows for context but the click affordance is hidden.
    let player: MeetingPlayer?

    var body: some View {
        let speaker = meta.speakers.first(where: { $0.id == segment.speakerId })
        let color = speaker.flatMap { Color(hex: $0.colorHex) } ?? .accentColor
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(speaker?.displayName ?? segment.speakerId)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    timestampButton
                }
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var timestampButton: some View {
        let label = Self.formatTimestamp(segment.start)
        if let player {
            Button {
                player.seek(to: segment.start)
                if !player.isPlaying { player.togglePlayPause() }
            } label: {
                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump the audio playback to this turn and start playing.")
        } else {
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Media-bar style play / pause + scrubber for the meeting's audio.
/// Sits between the speaker chips and the transcript turns.
private struct PlaybackBar: View {
    @Bindable var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            Text(Self.format(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .leading)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.scrub(to: $0) }
                ),
                in: 0...max(0.001, player.duration),
                onEditingChanged: { editing in
                    if editing { player.beginScrub() } else { player.endScrub() }
                }
            )

            Text(Self.format(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Surfaced in place of the playback bar when a meeting's audio isn't
/// playable here. Two reasons, two messages: the recording lives on another
/// Mac (only notes + transcript sync — audio stays put), or the audio was
/// pruned by the retention sweep. Tells the user why there's no play button so
/// they don't think it's broken.
private struct AudioMissingNote: View {
    /// True when the meeting's metadata says it has audio but the files aren't
    /// on this Mac — i.e. it was recorded on another Mac. False when the audio
    /// was genuinely removed locally by the retention sweep.
    var audioOnAnotherMac: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: audioOnAnotherMac ? "laptopcomputer.and.arrow.down" : "speaker.slash")
                .foregroundStyle(.secondary)
            Text(audioOnAnotherMac
                 ? "This recording stays on the Mac it was made on — only the notes and transcript sync between your Macs. Open the meeting on that Mac to play the audio."
                 : "Audio files for this meeting have been deleted to save space. The transcript is preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

/// Muted diarization-diagnostics chip sitting at the start of the speaker
/// chips row. Reports how many distinct speakers the diarizer (now run on
/// both mic and system tracks, merged via centroid similarity) settled on.
/// Lets the user catch obvious over- or under-clustering at a glance —
/// "expected 3 people on this call, the chip says 1" is a useful prompt
/// to re-process or report a bug. We deliberately don't surface the
/// overlap fraction because doing so cleanly would require persisting it
/// on the transcript schema, which is out of scope for the speaker-merge
/// task that introduced this chip.
private struct SpeakerCountChip: View {
    let count: Int
    /// True when the detected count looks implausible for the audio captured —
    /// e.g. a single speaker on a two-sided call, or an improbably high count.
    /// The chip turns amber and hints at Re-process so we're honest about
    /// diarization uncertainty rather than presenting a wrong count as fact.
    var suspicious: Bool = false

    var body: some View {
        MeetingChip(
            label,
            tone: suspicious ? .warning : .neutral,
            systemImage: "person.2.wave.2",
            trailingSystemImage: suspicious ? "exclamationmark.triangle.fill" : nil
        )
        .help(suspicious
            ? "This speaker count looks off for the audio captured. If it's wrong, use Re-process to run diarization again."
            : "Number of distinct speakers detected. Click any speaker chip to rename or recolour.")
    }

    private var label: String {
        count == 1 ? "1 speaker" : "\(count) speakers"
    }
}

/// Click-to-edit speaker chip. The chip itself renders identically to
/// the read-only v0.2 design; tapping it opens a popover for renaming
/// and recolouring. Changes flow through `session.renameSpeaker` /
/// `session.recolorSpeaker` so they persist to meta.json immediately.
private struct EditableSpeakerChip: View {
    let speaker: MeetingMeta.Speaker
    @Bindable var session: MeetingSession
    @State private var isEditing = false
    @State private var draftName: String = ""

    var body: some View {
        Button {
            draftName = speaker.displayName
            isEditing = true
        } label: {
            HStack(spacing: MeetingMetrics.chipInnerSpacing) {
                SpeakerBadge(speaker: speaker)
                Text(speaker.displayName)
                    .font(MeetingFonts.speakerLabel)
                if speaker.nameInferred {
                    Image(systemName: "sparkles")
                        .font(MeetingFonts.chipLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, MeetingMetrics.chipHPadding)
            .padding(.vertical, MeetingMetrics.chipVPadding)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(speaker.nameInferred
            ? "“\(speaker.displayName)” was auto-detected from the conversation — click to correct it."
            : "Click to rename or recolour this speaker.")
        .popover(isPresented: $isEditing, arrowEdge: .top) {
            SpeakerEditor(
                speaker: speaker,
                draftName: $draftName,
                onCommit: {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != speaker.displayName {
                        session.renameSpeaker(id: speaker.id, to: trimmed)
                    }
                    isEditing = false
                },
                onPickColor: { hex in
                    session.recolorSpeaker(id: speaker.id, hex: hex)
                }
            )
        }
    }
}

private struct SpeakerEditor: View {
    let speaker: MeetingMeta.Speaker
    @Binding var draftName: String
    let onCommit: () -> Void
    let onPickColor: (String) -> Void

    /// Same palette MeetingProcessor uses for new meetings, plus the
    /// "me" blue so the user can re-apply it after a wrong selection.
    private static let colorChoices: [String] = [
        "#5B9BD5",  // blue (me)
        "#ED7D31",  // orange
        "#70AD47",  // green
        "#A5A5A5",  // grey
        "#9966CC",  // purple
        "#E15554",  // red
        "#4B89DC",  // sky blue
        "#F4B400",  // amber
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit() }
                .frame(minWidth: 200)
            if speaker.nameInferred {
                Label("Auto-detected from the conversation — double-check it.", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Colour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                ForEach(Self.colorChoices, id: \.self) { hex in
                    Button {
                        onPickColor(hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(hex == speaker.colorHex ? Color.primary : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Done") { onCommit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// Meeting notes block — the primary content of the Notes tab. States:
///   1. Notes present → rendered markdown (editable), re-run button.
///   2. Legacy structured summary present (old meeting) → rendered via the
///      back-compat `SummaryBody`.
///   3. No notes yet, no LLM configured → muted hint pointing at Settings.
///   4. No notes yet, LLM configured → "Generate" button + hint.
private struct NotesPanel: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    let meta: MeetingMeta
    var onSeek: ((Double) -> Void)?
    @State private var assistant = MeetingAssistantController()

    /// There's something for the assistant to act on — notes exist and an LLM
    /// is configured. Gates both the prominent button and the hotkey hint.
    private var canUseAssistant: Bool {
        meta.notes != nil && state.settings.activeLLMEngine() != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Notes")
                    .font(.headline)
                if let notes = meta.notes, !notes.isFinal {
                    DraftChip()
                }
                if let notes = meta.notes, let type = notes.meetingType {
                    meetingTypeChip(type: type, detected: notes.meetingTypeWasDetected ?? false)
                }
                Spacer()
                if canUseAssistant {
                    Button { assistant.present() } label: {
                        Label("Assistant", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.assistantIndigo)
                    .controlSize(.small)
                    .help("Ask about or edit these notes with the on-device assistant.")
                }
                actionButton
            }
            if canUseAssistant, state.meetingsWindowIsKey {
                Label("\(state.settings.hotkeyTapToToggleEnabled ? "Tap" : "Hold") \(state.assistantHotkeyDisplay) to ask the assistant — by voice, hands-free.", systemImage: "mic")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            content
            if let err = session.notesError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notes = meta.notes {
                provenanceFooter(notes)
            }
        }
        .onAppear {
            assistant.bind(session: session)
            state.meetingAssistant = assistant
        }
        .onChange(of: session.id) { _, _ in
            assistant.bind(session: session)
            state.meetingAssistant = assistant
        }
        .onDisappear {
            assistant.dialogClosed()
            if state.meetingAssistant === assistant { state.meetingAssistant = nil }
        }
        .sheet(isPresented: $assistant.isPresented) {
            NotesAssistantSheet(assistant: assistant)
        }
    }

    /// The conversational shape these notes were written for — either the type
    /// the user configured, or the one auto-detected when the meeting was left
    /// on Auto (flagged with a sparkle, the same cue used for guessed speaker
    /// names). Tapping nothing here; it's informational. Sits beside the Notes
    /// header so it's the first thing read after "Notes".
    @ViewBuilder
    private func meetingTypeChip(type: MeetingType, detected: Bool) -> some View {
        MeetingChip(
            type.displayName,
            tone: detected ? .accent : .neutral,
            systemImage: detected ? "sparkles" : nil
        )
        .help(detected
            ? "Auto-detected from the conversation. Pick a style with Re-run ▾ to override."
            : "Notes style for this meeting. Change it with Re-run ▾.")
    }

    /// "Written by <model> · 2:14 PM" — turns the notes from an anonymous blob
    /// into an authored, timestamped artifact.
    @ViewBuilder
    private func provenanceFooter(_ notes: MeetingNotes) -> some View {
        HStack(spacing: 4) {
            Text(notes.isFinal ? "Written by" : "Draft by")
            Text(Self.modelDisplayName(notes.modelID)).foregroundStyle(.secondary)
            Text("·")
            Text(notes.generatedAt, format: .dateTime.hour().minute())
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private static func modelDisplayName(_ id: String) -> String {
        switch id {
        case "apple-foundation": return "Apple Foundation"
        case "none", "": return "the on-device model"
        default: return id.split(separator: "/").last.map(String.init) ?? id
        }
    }

    /// The notes body. When there are actual notes (or a legacy summary) they
    /// sit in the same `.notesSurface()` card the live-recording pane uses, so
    /// the finished notes read like the rough first pass did. The transient
    /// states (writing, hints) stay light.
    @ViewBuilder
    private var content: some View {
        if case .summarising = session.state {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(hasContent ? "Rewriting notes…" : "Writing notes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if let notes = meta.notes {
            MarkdownNotesView(
                markdown: notes.markdown,
                speakers: meta.speakers,
                onCommit: { session.updateNotesMarkdown($0) },
                onSeek: onSeek,
                onAssistant: nil   // entry point is the prominent header button now
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .notesSurface()
        } else if let summary = meta.summary {
            SummaryBody(summary: summary, meta: meta)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .notesSurface()
        } else if state.settings.activeLLMEngine() == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on an LLM to generate meeting notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings → Models") { state.openSettingsAction?() }
                    .controlSize(.small)
            }
        } else {
            Text("Generate markdown notes — a summary, the key discussion points, decisions, and action items for this meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hasContent: Bool { meta.notes != nil || meta.summary != nil }

    /// "Summarise as ▾" chevron menu — the primary verb (Generate / Re-run)
    /// uses whatever type the user has already pinned to this meeting (or
    /// the install-wide default when it's still on Auto-detect), and each
    /// menu row both pins a new type to the meeting AND kicks off a
    /// re-summary with it. Disabled while a summary is in flight or when
    /// no LLM is configured.
    @ViewBuilder
    private var actionButton: some View {
        let isSummarising: Bool = {
            if case .summarising = session.state { return true }
            return false
        }()
        let isEnabled = state.settings.activeLLMEngine() != nil && !isSummarising
        let primaryLabel = (meta.notes == nil && meta.summary == nil) ? "Generate" : "Re-run"

        Menu {
            Section("Notes for") {
                ForEach(MeetingType.allCases, id: \.self) { type in
                    Button {
                        generateNotes(as: type)
                    } label: {
                        if type == meta.meetingType {
                            Label(type.displayName, systemImage: "checkmark")
                        } else {
                            Text(type.displayName)
                        }
                    }
                }
            }
        } label: {
            Label(primaryLabel, systemImage: "wand.and.stars")
        } primaryAction: {
            Task { await session.generateNotes(settings: state.settings) }
        }
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!isEnabled)
    }

    /// Pin `type` to this meeting (store + session in lockstep) and kick
    /// off a fresh notes pass so the user sees the result of their choice
    /// immediately. The store write persists meta.json; the in-session
    /// mutation makes sure the next `generateNotes` resolves the new type
    /// without round-tripping via the store.
    private func generateNotes(as type: MeetingType) {
        MeetingsStore.shared.setMeetingType(id: meta.id, type: type)
        session.meta.meetingType = type
        Task { await session.generateNotes(settings: state.settings) }
    }
}

/// Small "Draft" pill shown on the notes header while the notes are the live
/// first-pass (`!isFinal`) — so a rough draft is never mistaken for the
/// finished, full-transcript notes.
private struct DraftChip: View {
    var body: some View {
        MeetingChip("Draft", tone: .draft, uppercased: true)
            .help("These are the rough notes built while recording. Re-run to write the full notes from the complete transcript.")
    }
}

private struct SummaryBody: View {
    let summary: MeetingSummaryResult
    let meta: MeetingMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.narrative.isEmpty {
                Text(summary.narrative)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Decisions")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, d in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(d).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }

            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action items")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            ActionItemRow(item: item, speakers: meta.speakers)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

/// One action-item line. When `owner` matches a speaker's display name
/// (case-insensitive), the owner renders as a coloured chip in the
/// matching speaker hue — so scanning the action list reads as
/// "at-a-glance: who's doing what". When the owner doesn't match any
/// speaker (the LLM occasionally pulls a name from inside the
/// transcript text rather than the speaker prefix), the chip falls
/// back to a neutral secondary tint instead of guessing a colour.
private struct ActionItemRow: View {
    let item: MeetingSummaryResult.ActionItem
    let speakers: [MeetingMeta.Speaker]

    var body: some View {
        if let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                OwnerChip(owner: owner, speakers: speakers)
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(item.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OwnerChip: View {
    let owner: String
    let speakers: [MeetingMeta.Speaker]

    var body: some View {
        let matched = speakers.first(where: { $0.displayName.compare(owner, options: .caseInsensitive) == .orderedSame })
        let tint = matched.flatMap { Color(hex: $0.colorHex) }
        // Slightly tinted background + matching foreground reads as
        // belonging to the same colour family as the speaker chip up in
        // the transcript header, without shouting for attention.
        HStack(spacing: 4) {
            if let matched {
                SpeakerBadge(speaker: matched)
            } else {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
            }
            Text(owner)
                .font(MeetingFonts.speakerLabel)
        }
        .padding(.horizontal, MeetingMetrics.chipHPadding)
        .padding(.vertical, MeetingMetrics.chipVPadding)
        .background(
            Capsule()
                .fill((tint ?? Color.secondary).opacity(matched == nil ? 0.15 : 0.18))
        )
        .foregroundStyle(tint ?? .secondary)
    }
}

private extension Color {
    /// The assistant's brand indigo (≈#5E5CE6), matching the dictation HUD's
    /// Assistant-Mode accent so the meeting assistant reads as the same feature.
    static let assistantIndigo = Color(red: 0.369, green: 0.361, blue: 0.902)

    /// Parse "#RRGGBB" hex strings stored in MeetingMeta.Speaker.
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >> 8) & 0xff) / 255
        let b = Double(value & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

/// Runs the on-device assistant against the meeting notes. Ask a question → get
/// an answer (the model returns DRAFT); ask for an edit → preview a rewrite and
/// apply it (REPLACE). Reuses the same `assist()` path and prompt as Assistant
/// Mode, with the notes passed as the selection so it has the full context.
private struct NotesAssistantSheet: View {
    @Bindable var assistant: MeetingAssistantController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Notes assistant", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(Color.assistantIndigo)
                Spacer()
                Button("Done") { assistant.isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Ask a question about these notes, or tell it how to edit them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("e.g. “What did we decide about pricing?” or “tighten the action items”", text: $assistant.instruction, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.run() }
                Button {
                    assistant.toggleListening()
                } label: {
                    Image(systemName: assistant.isListening ? "mic.fill" : "mic")
                        .foregroundStyle(assistant.isListening ? .red : .secondary)
                }
                .help(assistant.isListening ? "Stop and transcribe" : "Speak your instruction")
                .disabled(assistant.isTranscribing || assistant.isRunning)
                Button("Ask") { assistant.run() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.assistantIndigo)
                    .disabled(assistant.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isRunning || assistant.isListening)
            }

            if assistant.isListening {
                Label("Listening… tap the mic (or release the hotkey) to finish.", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if assistant.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if assistant.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let errorText = assistant.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let result = assistant.result {
                Divider()
                Text(result.mode == .replace ? "Suggested edit" : "Answer")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                ScrollView {
                    MarkdownNotesView(markdown: result.text, speakers: assistant.speakers)
                        .padding(12)
                }
                .frame(maxHeight: 280)
                .notesSurface()
                HStack {
                    CopyButton(text: result.text, label: "Copy")
                    Spacer()
                    if result.mode == .replace {
                        Button("Replace notes") { assistant.applyReplace() }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.assistantIndigo)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 580)
        .onDisappear { assistant.dialogClosed() }
    }
}
