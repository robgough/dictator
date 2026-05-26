import SwiftUI

/// Sidebar list of meetings. Newest first. Right-click → delete; selection
/// drives the detail pane via a binding.
struct MeetingSidebarList: View {
    @Binding var selection: UUID?
    let metas: [MeetingMeta]
    let onDelete: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(metas) { meta in
                MeetingSidebarRow(meta: meta)
                    .tag(meta.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(meta.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct MeetingSidebarRow: View {
    let meta: MeetingMeta

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: meta.source == .live ? "waveform.badge.mic" : "square.and.arrow.down")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let date = Self.dateFormatter.string(from: meta.createdAt)
        if meta.durationSeconds > 0 {
            return "\(date) · \(Self.formatDuration(meta.durationSeconds))"
        }
        return date
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDuration(_ seconds: Double) -> String {
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
