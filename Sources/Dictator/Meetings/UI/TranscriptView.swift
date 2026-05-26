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
                    SegmentRow(segment: segment, meta: meta)
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

    var body: some View {
        let speaker = meta.speakers.first(where: { $0.id == segment.speakerId })
        let color = speaker.flatMap { Color(hex: $0.colorHex) } ?? .accentColor
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(speaker?.displayName ?? segment.speakerId)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(0.001, player.duration)
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
                SummaryBody(summary: summary)
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

    @ViewBuilder
    private var actionButton: some View {
        let isSummarising: Bool = {
            if case .summarising = session.state { return true }
            return false
        }()
        let isEnabled = state.settings.activeLLMEngine() != nil && !isSummarising
        Button {
            Task { await session.runSummary(settings: state.settings) }
        } label: {
            Label(meta.summary == nil ? "Generate" : "Re-run", systemImage: "wand.and.stars")
        }
        .controlSize(.small)
        .disabled(!isEnabled)
    }
}

private struct SummaryBody: View {
    let summary: MeetingSummaryResult

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
                            if let owner = item.owner, !owner.isEmpty {
                                Text(.init("**\(owner)**: \(item.text)"))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(item.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
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
