import SwiftUI
import AppKit

/// Renders the chronological speaker turns for a ready meeting. Per-speaker
/// colour bar on the leading edge. Plain `Text(.textSelection(.enabled))`
/// so copy works.
struct TranscriptView: View {
    let meta: MeetingMeta
    let transcript: MeetingTranscript?
    @State private var player = MeetingPlayer()
    @State private var hasAudio: Bool = false

    var body: some View {
        if let transcript, !transcript.segments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(meta.speakers, id: \.id) { speaker in
                        SpeakerChip(speaker: speaker)
                    }
                    Spacer()
                    Button {
                        copyAll(transcript: transcript)
                    } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }

                if hasAudio {
                    PlaybackBar(player: player)
                } else {
                    AudioMissingNote()
                }

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

    private func copyAll(transcript: MeetingTranscript) {
        let rendered = transcript.segments.map { seg -> String in
            let name = meta.speakers.first(where: { $0.id == seg.speakerId })?.displayName ?? seg.speakerId
            return "\(name): \(seg.text)"
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered, forType: .string)
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

private struct SpeakerChip: View {
    let speaker: MeetingMeta.Speaker

    var body: some View {
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
