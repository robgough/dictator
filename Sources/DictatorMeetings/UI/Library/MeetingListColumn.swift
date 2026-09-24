import SwiftUI

/// The meeting column: the list the sidebar's scope picked, between the
/// sidebar and the meeting, the way Mail puts messages between mailboxes and
/// the message. Grouped into date sections like Notes and Mail, newest first.
///
/// Each row says where the meeting stands — notes written, or waiting for
/// them — so a meeting that still needs notes is visible from the list, not
/// only once it's opened. A recording in progress is pinned above the list.
struct MeetingListColumn: View {
    @Environment(MeetingsAppState.self) private var state
    let scope: LibraryScope
    @Binding var selection: UUID?
    let metas: [MeetingMeta]
    /// The recording in progress, if any, pinned above the list.
    let live: MeetingSession?
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Library.title(for: scope, settings: state.settings))
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Spacer()
                Text("\(metas.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if let live, live.isLive {
                LiveMeetingRow(session: live, selected: selection == live.id) {
                    selection = live.id
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            if metas.isEmpty {
                ContentUnavailableView(
                    scope == .needsNotes ? "Nothing waiting" : "No meetings",
                    systemImage: scope == .needsNotes ? "checkmark.circle" : "tray",
                    description: Text(scope == .needsNotes
                        ? "Every meeting has its notes written."
                        : "Meetings you record or import show up here."))
                    .frame(maxHeight: .infinity)
            } else {
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
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(meta.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if Library.needsNotes(meta) {
                    Text("Needs notes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.13)))
                        .help("The transcript is ready; the notes haven't been written.")
                } else if hasFinalNotes {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Notes written")
                }
            }
            HStack(spacing: 5) {
                Text(subtitle)
                if audioPruned {
                    Image(systemName: "doc.text").help("Audio removed — transcript kept")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }

    /// True only when the polished, end-of-meeting notes have been generated.
    /// Live/first-pass drafts (`isFinal == false`) deliberately don't light the
    /// badge — notes are written on demand now, so the sparkle means "done",
    /// not "a draft exists". The legacy structured `summary` counts as final.
    private var hasFinalNotes: Bool {
        meta.notes?.isFinal == true || meta.summary != nil
    }

    /// True when both audio tracks have been pruned (retention sweep) but the
    /// transcript remains — so the row hints the recording can't be re-processed.
    private var audioPruned: Bool {
        meta.audioFiles.mic == nil && meta.audioFiles.system == nil
    }

    /// When, how long, and who — the three things that tell two meetings with
    /// similar titles apart.
    private var subtitle: String {
        let when = Calendar.current.isDateInToday(meta.createdAt)
            ? Self.timeFormatter.string(from: meta.createdAt)
            : Self.dateTimeFormatter.string(from: meta.createdAt)
        var parts = [when]
        if meta.durationSeconds > 0 {
            parts.append(Self.formatDuration(meta.durationSeconds))
        }
        let others = meta.speakers.filter { !$0.isMe }.map { $0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName }
        if !others.isEmpty {
            parts.append(others.prefix(3).joined(separator: ", ") + (others.count > 3 ? " +\(others.count - 3)" : ""))
        }
        return parts.joined(separator: " · ")
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

/// The recording in progress, pinned above the meeting column: its title, the
/// time, and a live waveform of whoever is talking, so it's unmistakably the
/// one that's still happening.
private struct LiveMeetingRow: View {
    @Bindable var session: MeetingSession
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(session.meta.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(elapsed)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
                Waveform(level: level, tint: .red.opacity(0.65), honest: true, barCount: 40, height: 14)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.red.opacity(selected ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.45), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The meeting being recorded")
    }

    private var level: Float {
        if case .recording(_, let mic, let sys) = session.state { return max(mic, sys) }
        return 0
    }

    private var elapsed: String {
        guard case .recording(let t, _, _) = session.state else { return "0:00" }
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
