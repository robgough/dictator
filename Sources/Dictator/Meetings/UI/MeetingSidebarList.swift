import SwiftUI

/// Sidebar list of meetings, grouped into date sections (Today / Yesterday /
/// Previous 7 Days / Earlier) the way Notes and Mail group their lists.
/// Newest first within each section. Right-click → delete; selection drives
/// the detail pane via a binding.
struct MeetingSidebarList: View {
    @Binding var selection: UUID?
    let metas: [MeetingMeta]
    let onDelete: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(Self.grouped(metas), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.metas) { meta in
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
            }
        }
        .listStyle(.sidebar)
    }

    /// Bucket the (already newest-first) metas into date sections. Empty
    /// sections are dropped so the sidebar only shows headings that have rows.
    static func grouped(_ metas: [MeetingMeta]) -> [(title: String, metas: [MeetingMeta])] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        var today: [MeetingMeta] = []
        var yesterday: [MeetingMeta] = []
        var week: [MeetingMeta] = []
        var earlier: [MeetingMeta] = []
        for meta in metas {
            if meta.createdAt >= startOfToday { today.append(meta) }
            else if meta.createdAt >= startOfYesterday { yesterday.append(meta) }
            else if meta.createdAt >= startOfWeek { week.append(meta) }
            else { earlier.append(meta) }
        }
        return [
            ("Today", today),
            ("Yesterday", yesterday),
            ("Previous 7 Days", week),
            ("Earlier", earlier),
        ].filter { !$0.1.isEmpty }
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
                HStack(spacing: 5) {
                    Text(subtitle)
                    if meta.notes != nil || meta.summary != nil {
                        Image(systemName: "sparkles").help("Has notes")
                    }
                    if audioPruned {
                        Image(systemName: "doc.text").help("Audio removed — transcript kept")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// True when both audio tracks have been pruned (retention sweep) but the
    /// transcript remains — so the row hints the recording can't be re-processed.
    private var audioPruned: Bool {
        meta.audioFiles.mic == nil && meta.audioFiles.system == nil
    }

    private var subtitle: String {
        let when = Calendar.current.isDateInToday(meta.createdAt)
            ? Self.timeFormatter.string(from: meta.createdAt)
            : Self.dateTimeFormatter.string(from: meta.createdAt)
        if meta.durationSeconds > 0 {
            return "\(when) · \(Self.formatDuration(meta.durationSeconds))"
        }
        return when
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
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
