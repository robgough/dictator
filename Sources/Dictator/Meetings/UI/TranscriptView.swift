import SwiftUI
import AppKit

/// Renders the chronological speaker turns for a ready meeting. Per-speaker
/// colour bar on the leading edge. Plain `Text(.textSelection(.enabled))`
/// so copy works.
struct TranscriptView: View {
    let meta: MeetingMeta
    let transcript: MeetingTranscript?

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

                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    SegmentRow(segment: segment, meta: meta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
