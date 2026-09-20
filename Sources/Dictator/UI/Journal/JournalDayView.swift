import AppKit
import SwiftUI

/// A day of the journal, as a page.
///
/// Deliberately not the chat transcript. There is one author here, so there are
/// no sides, no bubbles and no tinted backgrounds — just a measure of text on
/// paper with the time in the margin, read top-down from the morning. The
/// window's background is `.textBackgroundColor` rather than window chrome,
/// which is most of why this reads as a document and the chat reads as a
/// conversation.
struct JournalDayView: View {
    @Bindable var shell: JournalShellModel
    @Environment(AppState.self) private var state
    @State private var store = JournalStore.shared
    @State private var isDropTarget = false

    /// Wide enough for comfortable prose, narrow enough to stay readable on a
    /// full-screen window.
    private let measure: CGFloat = 620

    var body: some View {
        Group {
            if store.daysUnavailable {
                JournalUnavailableView()
            } else {
                page
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter(JournalAttachments.isImage)
            guard !images.isEmpty else { return false }
            // A photo dropped on a past day still belongs to today, because
            // that's the only day an entry can be written to.
            store.selectToday()
            shell.pendingImages.append(contentsOf: images)
            shell.focusComposer()
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.hudMint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(
                get: { shell.confirmingDelete != nil },
                set: { if !$0 { shell.confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let entry = shell.confirmingDelete else { return }
                shell.confirmingDelete = nil
                Task { await store.delete(entry) }
            }
        } message: {
            Text("It's removed from the Markdown file. You can undo straight afterwards; any photos it showed stay in your journal folder.")
        }
    }

    // MARK: - The page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                    .padding(.bottom, 24)

                if store.groups.isEmpty && incomingPhase == nil {
                    emptyDay
                } else {
                    ForEach(store.groups) { group in
                        if store.groups.count > 1 {
                            fileCaption(group)
                        }
                        if let whole = group.wholeFile {
                            wholeFileBlock(whole)
                        } else {
                            ForEach(group.entries) { entry in
                                JournalEntryView(entry: entry, shell: shell)
                                    .padding(.bottom, 30)
                            }
                        }
                    }
                }

                // The entry being spoken, drawn where it will land. Without it
                // you speak, nothing on the page moves, and the words feel
                // lost until they appear several seconds later.
                if let incomingPhase, store.isShowingToday {
                    JournalIncomingEntry(phase: incomingPhase, pipeline: state.pipeline)
                        .id("incoming")
                }
            }
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: incomingPhase)
        .onChange(of: incomingPhase == nil) { _, idle in
            // Whichever way a journal capture started — the sidebar button or
            // the hotkey from another app — the page swings to today so the
            // entry can be watched arriving. The entry is going there
            // regardless; looking somewhere else while it lands is the thing
            // that made it feel lost.
            if !idle { store.selectToday() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let notice = store.notice {
                    noticeBar(notice)
                }
                if let undo = store.pendingUndo {
                    undoBar(undo)
                }
                if store.isShowingToday {
                    JournalComposer(shell: shell)
                } else {
                    pastDayBar
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            // The only serif in the app, and on purpose: it says "journal"
            // before a word of it is read, and New York is Apple's own
            // companion to SF, so it still belongs here.
            Text(longDate)
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)

            if !store.groups.isEmpty {
                Divider().padding(.top, 8)
                fileLine.padding(.top, 8)
            }
        }
    }

    private var fileLine: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let url = store.groups.first?.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.link)
    }

    /// Only drawn when a date is spread over more than one file — which happens
    /// after the path template changes, and is otherwise none of the user's
    /// business.
    private func fileCaption(_ group: JournalStore.FileGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 9))
            Text(group.url.lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.tertiary)
        .padding(.bottom, 10)
    }

    /// The fallback when the user's entry template writes no headings, so one
    /// entry can't be told from the next. Readable, not editable — pretending
    /// otherwise would mean guessing where an entry begins in order to rewrite
    /// somebody's file.
    private func wholeFileBlock(_ contents: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Your entry template doesn't start with a heading, so entries can't be told apart here. The day is shown whole.",
                systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(contents)
                .font(.system(size: 14))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 30)
    }

    // MARK: - States

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.isShowingToday ? "Nothing yet today." : "Nothing on this day.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            if store.days.isEmpty {
                Text("Hold \(journalHotkeyLabel) in any app to speak an entry, or write one below. Each day gets its own Markdown file, and nothing leaves this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var pastDayBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("New entries go to today.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Go to today") { store.selectToday() }
                .font(.caption)
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func noticeBar(_ notice: JournalStore.Notice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(notice.text)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                store.dismissNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The only safety net there is for a change to a file — there's no Trash
    /// for part of one — so it stays until the next change rather than fading.
    private func undoBar(_ pending: JournalStore.PendingUndo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
            Text(pending.what)
                .foregroundStyle(.secondary)
            Button("Undo") { Task { await store.undoLast() } }
                .buttonStyle(.link)
            Spacer(minLength: 0)
            Button {
                store.dismissUndo()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Text

    /// nil unless a *journal* capture is running — an ordinary dictation into
    /// another app has nothing to do with this page.
    private var incomingPhase: JournalCapturePhase? {
        JournalCapturePhase.current(state.pipeline)
    }

    private var selectedDate: Date? {
        store.selectedKey.flatMap(JournalStore.date(for:))
    }

    private var eyebrow: String {
        guard let date = selectedDate else { return "" }
        let weekday = Self.weekdayFormatter.string(from: date).uppercased()
        if let relative = JournalSidebar.relativeLabel(JournalStore.key(for: date)) {
            return "\(relative.uppercased()) · \(weekday)"
        }
        return weekday
    }

    private var longDate: String {
        guard let date = selectedDate else { return "" }
        return Self.longFormatter.string(from: date)
    }

    private var summary: String {
        let entries = store.groups.reduce(0) { $0 + $1.entries.count }
        let words = store.groups
            .flatMap(\.entries)
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        var parts: [String] = []
        if entries > 0 { parts.append("\(entries) \(entries == 1 ? "entry" : "entries")") }
        if words > 0 { parts.append("\(words) words") }
        if let name = store.groups.first?.url.lastPathComponent { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var journalHotkeyLabel: String {
        state.settings.journalTriggerMode == .keyboardShortcut ? "the journal hotkey" : "the journal trigger"
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter
    }()
}

/// Shown when the journal's file template can't produce one file per day, so
/// there is no calendar to draw.
///
/// Explained rather than hidden — the same call the chat window makes for a
/// model that can't run it. A journal in one long file is a perfectly
/// reasonable thing to have; it just isn't something this window can page
/// through by date.
struct JournalUnavailableView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("This window needs a file per day")
                .font(.title3.weight(.semibold))
            Text("Your journal writes to “\(state.settings.journalPathTemplate)”. The calendar finds days by the date in each filename, and that one doesn't have one. The default does — your entries are all still there either way.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Open Settings…") {
                SettingsWindowController.shared.show()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
