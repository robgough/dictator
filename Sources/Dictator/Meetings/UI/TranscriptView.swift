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

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    SpeakerCountChip(count: meta.speakers.count)
                    ForEach(meta.speakers, id: \.id) { speaker in
                        EditableSpeakerChip(speaker: speaker, session: session)
                    }
                    Spacer()
                    Button {
                        copyAll(transcript: transcript)
                    } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    Button {
                        exportTranscript(transcript: transcript)
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
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

                if hasAudio {
                    PlaybackBar(player: player)
                } else {
                    AudioMissingNote()
                }

                SummaryPanel(session: session, transcript: transcript, meta: meta)

                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    SegmentRow(
                        segment: segment,
                        meta: meta,
                        player: hasAudio ? player : nil
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { loadAudio() }
            .onDisappear { player.unload() }
            .onChange(of: meta.id) { _, _ in loadAudio() }
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

    private func copyAll(transcript: MeetingTranscript) {
        let rendered = MeetingExporter.plainText(transcript: transcript, meta: meta)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered, forType: .string)
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

/// Surfaced in place of the playback bar when a meeting's audio has been
/// pruned (per the retention setting) but its transcript is still on
/// disk. Tells the user why there's no play button so they don't think
/// it's broken.
private struct AudioMissingNote: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(.secondary)
            Text("Audio files for this meeting have been deleted to save space. The transcript is preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.wave.2")
                .font(.caption2)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .foregroundStyle(.secondary)
        .help("Number of distinct speakers detected. Click any speaker chip to rename or recolour.")
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
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: speaker.colorHex) ?? .accentColor)
                    .frame(width: 8, height: 8)
                Text(speaker.displayName)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
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

/// LLM summary block rendered above the transcript. Three states:
///   1. No summary yet, no LLM configured → muted hint pointing at Settings.
///   2. No summary yet, LLM configured → "Generate summary" button.
///   3. Summary present → decisions / action items / narrative, re-run button.
private struct SummaryPanel: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    let transcript: MeetingTranscript
    let meta: MeetingMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                actionButton
            }

            if case .summarising = session.state {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(meta.summary == nil ? "Generating summary…" : "Regenerating summary…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let summary = meta.summary {
                SummaryBody(summary: summary, meta: meta)
            } else if state.settings.activeLLMEngine() == nil {
                Text("Turn on an LLM in Settings → Models to summarise meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Generate a structured summary of decisions, action items, and the narrative arc of this meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.18), lineWidth: 1)
        )
    }

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
        let primaryLabel = meta.summary == nil ? "Generate" : "Re-run"

        Menu {
            Section("Summarise as") {
                ForEach(MeetingType.allCases, id: \.self) { type in
                    Button {
                        runSummary(as: type)
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
            Task { await session.runSummary(settings: state.settings) }
        }
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!isEnabled)
    }

    /// Pin `type` to this meeting (store + session in lockstep) and kick
    /// off a fresh summary so the user sees the result of their choice
    /// immediately. The store write persists meta.json; the in-session
    /// mutation makes sure the next `runSummary` resolves the new type
    /// without round-tripping via the store.
    private func runSummary(as type: MeetingType) {
        MeetingsStore.shared.setMeetingType(id: meta.id, type: type)
        session.meta.meetingType = type
        Task { await session.runSummary(settings: state.settings) }
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
            Circle()
                .fill(tint ?? Color.secondary)
                .frame(width: 6, height: 6)
            Text(owner)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill((tint ?? Color.secondary).opacity(matched == nil ? 0.15 : 0.18))
        )
        .foregroundStyle(tint ?? .secondary)
    }
}

private extension Color {
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
