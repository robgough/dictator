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
    @State private var inspection: MeetingTrackInspection?
    @State private var trackRows: [TrackRowBuilder.Row] = []
    /// Invalidates in-flight detached loads when the meeting changes under us.
    @State private var loadToken = UUID()

    /// Notes are the primary surface; the rough live "raw" notes (when kept)
    /// and the transcript (two-lane mic/system view) live behind other tabs.
    enum Tab: Hashable { case notes, raw, transcript }

    var body: some View {
        // The view owns its scrolling (the detail view used to) so the tab
        // picker stays fixed above and the playback dock can float at the
        // bottom of the viewport — pause/seek stay reachable however deep
        // into a transcript you've scrolled.
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch tab {
                        case .notes:
                            NotesPanel(session: session, meta: meta, onSeek: seekFromNotes)
                        case .raw:
                            rawTab
                        case .transcript:
                            transcriptTab
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasAudio {
                        playbackDock(proxy: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadAudio() }
        .onDisappear { player.unload() }
        .onChange(of: meta.id) { _, _ in
            loadAudio()
            if tab == .raw, !hasRawNotes { tab = .notes }
        }
        .onChange(of: session.state.isProcessing) { _, processing in
            // Re-process finished — pick up the freshly written track data.
            if !processing { loadAudio() }
        }
        .onChange(of: session.transcriptRevision) { _, _ in
            // Speaker merge rewrote the files in place.
            reloadInspection()
        }
        .background {
            // Keyboard shortcuts for the tab switch (hidden, zero-size).
            Button("") { tab = .notes }.keyboardShortcut("1", modifiers: .command)
            Button("") { tab = .transcript }.keyboardShortcut("2", modifiers: .command)
        }
    }

    /// Floating playback controls pinned to the bottom of the scroll
    /// viewport. The locate button scrolls the transcript to the line under
    /// the playhead.
    private func playbackDock(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            PlaybackBar(player: player)
            Button {
                jumpToPlayhead(proxy)
            } label: {
                Image(systemName: "text.line.magnify")
            }
            .buttonStyle(.plain)
            .help("Show the transcript line at the playhead.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Scroll the transcript to the row containing (or nearest before) the
    /// playhead. Switches to the transcript tab first if needed.
    private func jumpToPlayhead(_ proxy: ScrollViewProxy) {
        if tab != .transcript { tab = .transcript }
        let t = player.currentTime
        if !trackRows.isEmpty {
            // Speech rows only — short gate-silence rows are filtered from
            // display, so scrolling to one would target a missing anchor.
            func isSpeech(_ row: TrackRowBuilder.Row) -> Bool {
                if case .speech = row.kind { return true }
                return false
            }
            let target = trackRows.last(where: { $0.start <= t && isSpeech($0) })
                ?? trackRows.first(where: isSpeech)
            if let target {
                withAnimation { proxy.scrollTo("trackrow-\(target.id)", anchor: .center) }
            }
        } else if let transcript, !transcript.segments.isEmpty {
            let idx = transcript.segments.lastIndex(where: { $0.start <= t }) ?? 0
            withAnimation { proxy.scrollTo("segment-\(idx)", anchor: .center) }
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

            if hasCopyableContent {
                // The export text itself is built lazily on click
                // (CopyButton's autoclosure) — rendering it eagerly here made
                // every body evaluation pay for a full-document export.
                CopyButton(text: currentTabCopyText ?? "", label: copyLabel)
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

    /// The transcript tab is the two-lane mic/system view when track data
    /// exists (it shows everything the cleanup passes did), falling back to
    /// the legacy merged-segment list for meetings processed before
    /// tracks.json existed.
    @ViewBuilder
    private var transcriptTab: some View {
        let hasTracks = inspection != nil && !trackRows.isEmpty
        if hasTracks || (transcript.map { !$0.segments.isEmpty } ?? false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    SpeakerCountChip(count: meta.speakers.count, suspicious: speakerCountLooksOff)
                    ForEach(meta.speakers, id: \.id) { speaker in
                        EditableSpeakerChip(speaker: speaker, session: session, allSpeakers: meta.speakers)
                    }
                    Spacer()
                }

                if !hasAudio {
                    AudioMissingNote(
                        audioOnAnotherMac: meta.audioFiles.mic != nil || meta.audioFiles.system != nil
                    )
                }

                if let inspection, hasTracks {
                    TracksPanel(
                        inspection: inspection,
                        rows: trackRows,
                        meta: meta,
                        player: hasAudio ? player : nil
                    )
                } else if let transcript {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(transcript.segments.enumerated()), id: \.offset) { idx, segment in
                            SegmentRow(
                                segment: segment,
                                meta: meta,
                                player: hasAudio ? player : nil
                            )
                            .id("segment-\(idx)")
                        }
                    }
                    Text("Re-process this meeting to get the per-track view (mic and call audio side by side).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
        reloadInspection()
    }

    /// Decode tracks.json and build the row model off the main thread — a
    /// long meeting's track data runs to megabytes / tens of thousands of
    /// words, and doing this synchronously froze the page switch. The token
    /// guards against a stale load landing after the user changed meeting.
    private func reloadInspection() {
        inspection = nil
        trackRows = []
        let id = meta.id
        let token = UUID()
        loadToken = token
        Task.detached(priority: .userInitiated) {
            let insp = MeetingStorage.readTrackInspection(for: id)
            let rows = insp.map { TrackRowBuilder.rows(inspection: $0) } ?? []
            let micSpeech = insp.map { Self.speechIntervals($0.mic) } ?? []
            let systemSpeech = insp.map { Self.speechIntervals($0.system) } ?? []
            await MainActor.run {
                guard loadToken == token else { return }
                inspection = insp
                trackRows = rows
                player.setSpeechIntervals(mic: micSpeech, system: systemSpeech)
                player.setTrackLevels(mic: insp?.micSpeechLevel, system: insp?.systemSpeechLevel)
            }
        }
    }

    /// Kept words → padded, merged speech intervals for playback ducking.
    private nonisolated static func speechIntervals(
        _ words: [MeetingTrackInspection.Word]
    ) -> [(start: Double, end: Double)] {
        let pad = 0.25
        let mergeGap = 0.6
        var intervals: [(start: Double, end: Double)] = []
        for word in words where word.dropped == nil {
            let s = word.start - pad, e = word.end + pad
            if let last = intervals.last, s - last.end <= mergeGap {
                intervals[intervals.count - 1].end = max(last.end, e)
            } else {
                intervals.append((s, e))
            }
        }
        return intervals
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

    /// Cheap presence check so the header can show/hide the copy button
    /// without rendering the (expensive) export text.
    private var hasCopyableContent: Bool {
        switch tab {
        case .notes:
            return meta.notes != nil || transcript != nil
        case .raw:
            return meta.rawNotes != nil
        case .transcript:
            return (transcript.map { !$0.segments.isEmpty } ?? false) || inspection != nil
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
            // The merged transcript is the shareable artifact; the two-lane
            // diagnostic text has its own copy button in the lanes summary.
            guard let transcript, !transcript.segments.isEmpty else {
                guard let inspection else { return nil }
                return TrackRowBuilder.plainText(inspection: inspection, meta: meta)
            }
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
    /// Full speaker list, for the merge menu's targets.
    var allSpeakers: [MeetingMeta.Speaker] = []
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
            : "Click to rename or recolour this speaker. Right-click to merge with another speaker.")
        .contextMenu {
            // Manual fix for an over-split diarization: fold this chip's
            // words into another speaker. Re-processing re-runs diarization
            // and may split them again.
            let targets = allSpeakers.filter { $0.id != speaker.id }
            if !targets.isEmpty {
                Menu("Merge into") {
                    ForEach(targets, id: \.id) { target in
                        Button("\(target.displayName)") {
                            session.mergeSpeaker(id: speaker.id, into: target.id)
                        }
                    }
                }
                .help("This speaker's words are re-attributed to the one you pick, and this chip disappears. Use when the same person was split into two speakers.")
            }
        }
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

// MARK: - Two-track inspection (Tracks tab)

/// Shared row model for the Tracks tab and its copy-as-text export. Words are
/// grouped into compact runs per track (same speaker, same drop reason, small
/// gaps), interleaved with the gate's silenced ranges, and sorted onto one
/// time axis.
private enum TrackRowBuilder {
    enum Lane { case mic, system }

    enum Kind: Equatable {
        case speech(speakerId: String, text: String, dropped: MeetingTrackInspection.DropReason?)
        case gateSilence
    }

    struct Row: Identifiable {
        var id: Int
        let lane: Lane
        let start: Double
        let end: Double
        let kind: Kind
    }

    /// Words further apart than this break a run (matches the merged
    /// transcript's turn gap — sub-second gaps are normal ASR timing and
    /// splitting on them shredded speech into single-word rows).
    private static let groupGap = 2.5
    /// Cap runs so a long monologue doesn't become one giant cell that
    /// defeats the side-by-side reading.
    private static let groupMaxWords = 60

    static func rows(inspection: MeetingTrackInspection) -> [Row] {
        var rows: [Row] = []
        func addGroups(_ words: [MeetingTrackInspection.Word], lane: Lane) {
            var i = 0
            while i < words.count {
                let head = words[i]
                var j = i + 1
                while j < words.count,
                      j - i < groupMaxWords,
                      words[j].speakerId == head.speakerId,
                      words[j].dropped == head.dropped,
                      words[j].start - words[j - 1].end <= groupGap {
                    j += 1
                }
                rows.append(Row(
                    id: 0,
                    lane: lane,
                    start: head.start,
                    end: words[j - 1].end,
                    kind: .speech(
                        speakerId: head.speakerId,
                        text: words[i..<j].map(\.text).joined(separator: " "),
                        dropped: head.dropped
                    )
                ))
                i = j
            }
        }
        addGroups(inspection.mic, lane: .mic)
        addGroups(inspection.system, lane: .system)
        for range in inspection.gate?.silencedRanges ?? [] {
            rows.append(Row(id: 0, lane: .mic, start: range.start, end: range.end, kind: .gateSilence))
        }
        rows.sort { $0.start < $1.start }
        for i in rows.indices { rows[i].id = i }
        return rows
    }

    /// Resolve a display name; bleed-dropped clusters aren't in the meta
    /// palette (they never surface as chips) so they get a fixed label.
    static func displayName(for speakerId: String, meta: MeetingMeta) -> String {
        if speakerId == MeetingProcessor.bleedSpeakerID { return "Bleed" }
        return meta.speakers.first(where: { $0.id == speakerId })?.displayName ?? speakerId
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// The whole view as paste-friendly text — handy for sharing a diagnosis.
    static func plainText(inspection: MeetingTrackInspection, meta: MeetingMeta) -> String {
        var lines: [String] = []
        if let gate = inspection.gate {
            lines.append(String(
                format: "Bleed gate: %@  corr=%.2f offset=%+.2fs gain=%.3f silenced=%.0f%%",
                gate.applied ? "applied" : "skipped",
                gate.correlation, gate.offsetSeconds, gate.gain, gate.droppedFraction * 100
            ))
            lines.append("")
        }
        for row in rows(inspection: inspection) {
            let lane = row.lane == .mic ? "MIC" : "SYS"
            switch row.kind {
            case .gateSilence:
                lines.append("[\(timestamp(row.start))–\(timestamp(row.end))] \(lane)  — audio silenced by bleed gate —")
            case .speech(let speakerId, let text, let dropped):
                var suffix = ""
                if let dropped {
                    suffix = dropped == .bleedCluster ? "  [dropped: bleed]" : "  [dropped: echo]"
                }
                lines.append("[\(timestamp(row.start))] \(lane)  \(displayName(for: speakerId, meta: meta)): \(text)\(suffix)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The Tracks tab: mic and system transcriptions side by side on one
/// chronological axis, with everything the cleanup passes removed still
/// visible — struck-through words for the bleed/echo drops, shaded bands
/// where the audio gate silenced mic audio before transcription saw it.
private struct TracksPanel: View {
    let inspection: MeetingTrackInspection
    /// Precomputed off-main by the owner — building the row model inline
    /// here would redo a 15k-word pass on every body evaluation.
    let rows: [TrackRowBuilder.Row]
    let meta: MeetingMeta
    let player: MeetingPlayer?

    /// Hide gate-silence markers below this length. The gate routinely
    /// silences a hundred-plus short bleed slivers per call — a marker for
    /// each drowned the conversation; only a long contiguous removal is
    /// worth a line in the flow. The full list stays in the copy text.
    private static let minVisibleSilence: Double = 15

    /// One visible row plus its layout relationship to the previous one —
    /// time-overlapping turns draw tighter (and literally overlapping when
    /// the bubbles sit on opposite sides) so simultaneous speech reads as
    /// people talking over each other.
    private struct DisplayRow: Identifiable {
        let row: TrackRowBuilder.Row
        let topPadding: CGFloat
        var id: Int { row.id }
    }

    private var displayRows: [DisplayRow] {
        let visible = rows.filter { row in
            if case .gateSilence = row.kind { return row.end - row.start >= Self.minVisibleSilence }
            return true
        }
        var out: [DisplayRow] = []
        out.reserveCapacity(visible.count)
        var previous: TrackRowBuilder.Row?
        for row in visible {
            var padding: CGFloat = 12
            if let previous {
                let overlaps = row.start < previous.end - 0.05
                if overlaps {
                    let opposite = Self.isMeSide(previous.kind) != Self.isMeSide(row.kind)
                    padding = opposite ? -6 : 2
                }
            } else {
                padding = 0
            }
            out.append(DisplayRow(row: row, topPadding: padding))
            previous = row
        }
        return out
    }

    /// Which side a row's bubble sits on (true = trailing/"me"); nil for
    /// the centered silence markers.
    private static func isMeSide(_ kind: TrackRowBuilder.Kind) -> Bool? {
        if case .speech(let speakerId, _, _) = kind { return speakerId == "me" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayRows) { display in
                    TrackRowView(row: display.row, meta: meta, player: player)
                        .padding(.top, display.topPadding)
                        .id("trackrow-\(display.row.id)")
                }
            }
        }
    }

    /// One-glance stats: word counts per track with drop tallies, plus what
    /// the audio gate decided and why.
    private var summary: some View {
        let micKept = inspection.mic.count(where: { $0.dropped == nil })
        let micBleed = inspection.mic.count(where: { $0.dropped == .bleedCluster })
        let micEcho = inspection.mic.count(where: { $0.dropped == .echoDedup })
        var micLine = "Mic: \(micKept) words kept"
        if micBleed > 0 { micLine += ", \(micBleed) dropped as bleed" }
        if micEcho > 0 { micLine += ", \(micEcho) dropped as echoes" }
        micLine += " · System: \(inspection.system.count) words"

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(micLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CopyButton(text: TrackRowBuilder.plainText(inspection: inspection, meta: meta))
                    .help("Copy the two-lane comparison as text — handy for sharing a diagnosis.")
            }
            if let gate = inspection.gate {
                Text(gate.applied
                    ? String(format: "Bleed gate: applied — correlation %.2f, start offset %+.2f s, coupling %.3f, %.0f%% of mic audio silenced",
                             gate.correlation, gate.offsetSeconds, gate.gain, gate.droppedFraction * 100)
                    : String(format: "Bleed gate: not applied (correlation %.2f — tracks uncorrelated, no bleed pattern)",
                             gate.correlation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One chat bubble (or silence marker) in the conversation-styled
/// transcript. "Me" sits trailing (messaging convention), every other
/// voice leads; dropped words render as dimmed struck-through bubbles so
/// the cleanup stays visible without dominating.
private struct TrackRowView: View {
    let row: TrackRowBuilder.Row
    let meta: MeetingMeta
    let player: MeetingPlayer?

    /// True while the playhead sits inside this row. Only instantiated
    /// (visible) rows observe `currentTime`, so the ~20 Hz tick re-renders
    /// a screenful of rows, not the whole transcript.
    private var isAtPlayhead: Bool {
        guard let player, player.isPlaying else { return false }
        return player.currentTime >= row.start - 0.1 && player.currentTime <= row.end + 0.1
    }

    var body: some View {
        switch row.kind {
        case .gateSilence:
            silenceMarker
        case .speech(let speakerId, let text, let dropped):
            bubble(speakerId: speakerId, text: text, dropped: dropped)
        }
    }

    /// A long gate removal, shown as a quiet centered marker rather than a
    /// bubble — it's an absence, not a turn.
    private var silenceMarker: some View {
        HStack {
            Spacer()
            Label(
                "\(Int(row.end - row.start)) s of mic audio removed as bleed",
                systemImage: "waveform.slash"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func bubble(speakerId: String, text: String, dropped: MeetingTrackInspection.DropReason?) -> some View {
        let isMe = speakerId == "me"
        let color = speakerColorFor(speakerId)
        HStack(spacing: 0) {
            if isMe { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !isMe {
                        Text(TrackRowBuilder.displayName(for: speakerId, meta: meta))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color)
                    }
                    timestamp
                    if let dropped {
                        Text(dropped == .bleedCluster ? "bleed" : "echo")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(text)
                    .font(.callout)
                    .strikethrough(dropped != nil)
                    .foregroundStyle(dropped != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(dropped != nil ? 0.05 : 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isAtPlayhead ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
            )
            .opacity(dropped != nil ? 0.6 : 1)
            .frame(maxWidth: 560, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
    }

    private func speakerColorFor(_ speakerId: String) -> Color {
        if speakerId == MeetingProcessor.bleedSpeakerID { return .orange }
        if let speaker = meta.speakers.first(where: { $0.id == speakerId }) {
            return Color(hex: speaker.colorHex) ?? .accentColor
        }
        return .secondary
    }

    @ViewBuilder
    private var timestamp: some View {
        let label = TrackRowBuilder.timestamp(row.start)
        if let player {
            Button {
                player.seek(to: row.start)
                if !player.isPlaying { player.togglePlayPause() }
            } label: {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Jump the audio playback here.")
        } else {
            Text(label)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}
