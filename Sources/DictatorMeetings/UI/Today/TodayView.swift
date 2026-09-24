import SwiftUI

/// The home screen: what's next on the calendar, what's waiting for notes,
/// and what people said they'd do.
///
/// Everything here is a way into somewhere else — record the next call, open
/// a meeting to write its notes, jump to the meeting an action item came
/// from. Nothing is edited here except ticking an action item, which writes
/// straight back into that meeting's notes.
struct TodayView: View {
    @Environment(MeetingsAppState.self) private var state
    let metas: [MeetingMeta]
    let live: MeetingSession?
    let onRecord: () -> Void
    /// Open a meeting, in the list that best explains why it was opened.
    let onOpen: (UUID, LibraryScope) -> Void
    let onOpenLive: () -> Void

    @State private var upcoming = UpcomingMeetings.shared
    /// Action items, worked out off the main thread whenever the meetings
    /// change — parsing every meeting's notes on every redraw is what a
    /// screen you glance at shouldn't cost.
    @State private var mine: [ActionItem] = []
    @State private var others: [ActionItem] = []
    @State private var anyItems = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let live, live.isLive {
                    LiveNowCard(session: live, onOpen: onOpenLive)
                }
                UpNextCard(upcoming: upcoming, onRecord: onRecord)
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 24) {
                        waitingForNotes
                        earlierToday
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    actionItems
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1000, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .task { await upcoming.refresh(settings: state.settings) }
        .task(id: metas) {
            let metas = self.metas
            let userName = state.settings.userName
            let result = await Task.detached(priority: .userInitiated) {
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
                let recent = metas.filter { $0.createdAt >= cutoff }
                let open = ActionItems.collect(from: recent).filter { !$0.done }
                let byID = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })
                let mine = open.filter { ActionItems.isMine($0, meta: byID[$0.meetingID], userName: userName) }
                let others = open.filter { !ActionItems.isMine($0, meta: byID[$0.meetingID], userName: userName) }
                return (mine, others, !open.isEmpty)
            }.value
            mine = result.0
            others = result.1
            anyItems = result.2
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Today")
                    .font(.largeTitle.weight(.bold))
            }
            Spacer()
            if live?.isLive != true {
                Button(action: onRecord) {
                    Label("Record now", systemImage: "record.circle")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Waiting for notes

    private var waiting: [MeetingMeta] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .distantPast
        return metas.filter { Library.needsNotes($0) && $0.createdAt >= cutoff && $0.id != live?.id }
    }

    @ViewBuilder
    private var waitingForNotes: some View {
        let items = waiting
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Waiting for notes", count: items.count)
            if items.isEmpty {
                quiet("Every recent meeting has its notes written.")
            } else {
                ForEach(items.prefix(5)) { meta in
                    WaitingRow(meta: meta) { onOpen(meta.id, .needsNotes) }
                }
                if items.count > 5 {
                    Button("See all \(items.count)") { onOpen(items[5].id, .needsNotes) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - Earlier today

    @ViewBuilder
    private var earlierToday: some View {
        let today = metas.filter { Calendar.current.isDateInToday($0.createdAt) && Library.hasFinalNotes($0) }
        if !today.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Earlier today", count: nil)
                ForEach(today.prefix(4)) { meta in
                    Button { onOpen(meta.id, .all) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(.purple)
                                Text(meta.title).font(.body.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(meta.createdAt, format: .dateTime.hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let line = Self.summaryLine(meta) {
                                Text(line)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .notesSurface()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// "today", "yesterday", "Monday", then a date — the way a person says
    /// when a meeting was, and never "in 6 hours" for one that's over.
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The first sentence of a meeting's summary — enough to remember which
    /// meeting it was.
    static func summaryLine(_ meta: MeetingMeta) -> String? {
        guard let markdown = meta.notes?.markdown else { return meta.summary?.narrative }
        var inSummary = false
        for block in MarkdownBlock.parse(markdown) {
            if block.kind == .heading {
                inSummary = block.text.lowercased().contains("summary")
            } else if inSummary, block.kind == .paragraph || block.kind == .bullet {
                let text = block.text.replacingOccurrences(of: "**", with: "")
                if let end = text.range(of: ". ") { return String(text[..<end.lowerBound]) + "." }
                return text
            }
        }
        return nil
    }

    // MARK: - Action items

    @ViewBuilder
    private var actionItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Your action items", count: mine.count)
            if mine.isEmpty {
                quiet(!anyItems
                      ? "Action items from your meetings' notes collect here."
                      : "Nothing of yours is outstanding.")
            } else {
                itemList(Array(mine.prefix(8)), showOwner: false)
            }
            if !others.isEmpty {
                sectionHeading("Waiting on others", count: others.count)
                    .padding(.top, 12)
                itemList(Array(others.prefix(8)), showOwner: true)
            }
        }
    }

    private func itemList(_ items: [ActionItem], showOwner: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                ActionItemRow(item: item, showOwner: showOwner) {
                    onOpen(item.meetingID, .all)
                }
                if item.id != items.last?.id { Divider().padding(.leading, 34) }
            }
        }
        .padding(.vertical, 4)
        .notesSurface()
    }

    // MARK: - Bits

    private func sectionHeading(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let count, count > 0 {
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

// MARK: - Cards

/// What's next on the calendar, with the one decision that matters before a
/// call: record it or don't.
private struct UpNextCard: View {
    @Environment(MeetingsAppState.self) private var state
    @Bindable var upcoming: UpcomingMeetings
    let onRecord: () -> Void

    var body: some View {
        switch upcoming.access {
        case .off:
            EmptyView()
        case .unknown:
            HStack(spacing: 14) {
                icon("calendar")
                VStack(alignment: .leading, spacing: 3) {
                    Text("See what's next").font(.headline)
                    Text("Show your next meeting here, and record it the moment it starts. The calendar is only read on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect Calendar") {
                    Task { await upcoming.requestAccess(settings: state.settings) }
                }
                .buttonStyle(.glass)
            }
            .padding(18)
            .notesSurface()
        case .denied:
            Text("Calendar access is off for Dictator Meetings in System Settings → Privacy & Security → Calendars.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .granted:
            if let event = upcoming.next {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    eventCard(event, now: context.date)
                }
            } else {
                Label("Nothing else on your calendar today.", systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func eventCard(_ event: UpcomingMeetings.Event, now: Date) -> some View {
        let started = event.start <= now
        let armed = upcoming.armedEventID == event.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(spacing: 0) {
                    Text(started ? "NOW" : "IN")
                        .font(.caption2.weight(.bold))
                    if !started {
                        Text(Self.countdown(to: event.start, from: now))
                            .font(.title3.weight(.bold).monospacedDigit())
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title3.weight(.bold))
                    }
                }
                .foregroundStyle(.blue)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.blue.opacity(0.11)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    Text(event.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(detail(event)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    if started {
                        Button(action: onRecord) {
                            Label("Record now", systemImage: "record.circle.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.red)
                    } else if armed {
                        Label("Records at \(event.start.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                        Button("Don't record") { upcoming.disarm() }
                            .buttonStyle(.link)
                            .font(.caption)
                    } else {
                        Button {
                            upcoming.arm(event)
                        } label: {
                            Label("Record when it starts", systemImage: "record.circle")
                        }
                        .buttonStyle(.glassProminent)
                        .help("Starts recording at \(event.start.formatted(date: .omitted, time: .shortened)), as long as this Mac is awake and Dictator Meetings is running.")
                    }
                    if let url = event.joinURL, let service = event.joinService {
                        Button("Join \(service)") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            let later = upcoming.events.dropFirst().prefix(3)
            if !later.isEmpty {
                Divider()
                HStack(spacing: 18) {
                    Text("Later").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(later)) { next in
                        HStack(spacing: 5) {
                            Text(next.start, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Text(next.title).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .notesSurface()
    }

    private func detail(_ event: UpcomingMeetings.Event) -> String {
        var parts = ["\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"]
        if let service = event.joinService { parts.append(service) }
        if event.attendeeCount > 0 { parts.append(event.attendeeCount == 1 ? "1 person" : "\(event.attendeeCount) people") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(.blue)
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.11)))
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h\(minutes % 60)"
    }
}

/// The recording in progress, at the top of Today while it runs.
private struct LiveNowCard: View {
    @Bindable var session: MeetingSession
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(.red).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording now").font(.caption.weight(.semibold)).foregroundStyle(.red)
                Text(session.meta.title).font(.title3.weight(.semibold)).lineLimit(1)
            }
            Waveform(level: level, tint: .red.opacity(0.7), honest: true, barCount: 30, height: 22)
                .frame(width: 150)
            Spacer()
            Button("Open", action: onOpen).buttonStyle(.glass)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: MeetingMetrics.cardCornerRadius, style: .continuous).fill(Color.red.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: MeetingMetrics.cardCornerRadius, style: .continuous).strokeBorder(Color.red.opacity(0.35), lineWidth: 1.5))
    }

    private var level: Float {
        if case .recording(_, let mic, let sys) = session.state { return max(mic, sys) }
        return 0
    }
}

private struct WaitingRow: View {
    let meta: MeetingMeta
    let onWrite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meta.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onWrite) {
                Label("Write notes", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.small)
        }
        .padding(14)
        .notesSurface()
    }

    private var subtitle: String {
        var parts = [TodayView.day(meta.createdAt)]
        if meta.durationSeconds > 0 { parts.append("\(Int((meta.durationSeconds / 60).rounded())) min") }
        let unsure = meta.speakers.filter { $0.nameInferred || $0.displayName.lowercased().hasPrefix("speaker") }.count
        if unsure > 0 { parts.append(unsure == 1 ? "1 speaker to check" : "\(unsure) speakers to check") }
        return parts.joined(separator: " · ")
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let showOwner: Bool
    let onOpenMeeting: () -> Void
    @State private var ticked = false

    /// Owners come off the front of the line ("**Priya** — rewrite…"),
    /// which leaves the rest starting lower-case.
    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                ticked = true
                // A beat so the tick is seen before the row leaves the list.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    ActionItems.setDone(item, done: true)
                }
            } label: {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(ticked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Mark done — this ticks it in the meeting's notes too")
            VStack(alignment: .leading, spacing: 2) {
                inlineMarkdownText(Self.sentenceCase(item.text))
                    .font(.callout)
                    .strikethrough(ticked)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenMeeting) {
                    Text("\(showOwner && item.owner != nil ? "\(item.owner!) · " : "")\(item.meetingTitle) · \(TodayView.day(item.meetingDate))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open the meeting this came from")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
