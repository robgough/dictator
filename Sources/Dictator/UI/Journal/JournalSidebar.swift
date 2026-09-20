import SwiftUI

/// Pick a day.
///
/// A calendar rather than a list of dates, because that's the shape the
/// question has: people look for "that Tuesday", not for row 419. A five-year
/// archive is 1,800 rows as a list and sixty taps as a month-by-month calendar,
/// so the month name is also a menu of the months that actually have something
/// in them — two clicks to anywhere, however long the journal runs.
///
/// The dots cost nothing, which is what makes this affordable: every date comes
/// out of a filename (`JournalArchive.days()`), and no file is opened to draw
/// the month.
struct JournalSidebar: View {
    @Bindable var shell: JournalShellModel
    @State private var store = JournalStore.shared

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            monthHeader
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            weekdayRow
                .padding(.horizontal, 12)

            monthGrid
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)

            Divider()

            recentList

            // The window's primary action, at the bottom of the sidebar rather
            // than in the toolbar: it works whatever day is showing, which
            // leaves the page on the right to be nothing but the journal.
            JournalRecordButton()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            if let key = store.selectedKey, let date = JournalStore.date(for: key) {
                shell.visibleMonth = date
            }
        }
        .onChange(of: store.selectedKey) { _, key in
            // Following the selection keeps the grid honest when a day is
            // chosen from somewhere else — the Recent list, or an entry
            // landing from the hotkey.
            guard let key, let date = JournalStore.date(for: key) else { return }
            if !calendar.isDate(date, equalTo: shell.visibleMonth, toGranularity: .month) {
                shell.visibleMonth = date
            }
        }
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(monthsWithEntries, id: \.self) { month in
                    Button(Self.monthYearFormatter.string(from: month)) {
                        shell.visibleMonth = month
                    }
                }
            } label: {
                Text(Self.monthYearFormatter.string(from: shell.visibleMonth))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(monthsWithEntries.isEmpty ? .hidden : .visible)
            .fixedSize()
            .disabled(monthsWithEntries.isEmpty)

            Spacer(minLength: 0)

            Button { step(by: -1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month")
            Button { step(by: 1) } label: { Image(systemName: "chevron.right") }
                .help("Next month")
            Button("Today") {
                shell.visibleMonth = Date()
                store.selectToday()
            }
            .font(.system(size: 11, weight: .medium))
            .help("Jump to today")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
            ForEach(Array(gridDates.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 28)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let key = JournalStore.key(for: date)
        let isSelected = key == store.selectedKey
        let isToday = calendar.isDateInToday(date)
        let hasEntries = store.populatedKeys.contains(key)
        return Button {
            store.select(key: key)
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(numberStyle(isSelected: isSelected, isToday: isToday))
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(Color.hudMint))
                    .frame(width: 4, height: 4)
                    .opacity(hasEntries ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                if isSelected {
                    Circle().fill(Color.hudMint).frame(width: 28, height: 28)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.longDateFormatter.string(from: date))
    }

    private func numberStyle(isSelected: Bool, isToday: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(Color.hudMint) }
        return AnyShapeStyle(.primary)
    }

    // MARK: - Recent

    /// The last few days with something in them, wherever they fall.
    ///
    /// Not a second copy of the calendar: this is the "take me back to what I
    /// was writing" list, and it crosses month boundaries, which the grid
    /// can't. No previews and no counts — both would mean opening every file
    /// in the month to draw a sidebar (measured at 184 ms on a five-year
    /// archive in `JournalArchive`), and the page itself is one click away.
    private var recentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.days.prefix(12)) { day in
                    recentRow(day)
                }
            }
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
        .overlay {
            if store.days.isEmpty {
                Text("Nothing written yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
            }
        }
    }

    private func recentRow(_ day: JournalArchive.Day) -> some View {
        let isSelected = day.key == store.selectedKey
        return Button {
            store.select(key: day.key)
        } label: {
            HStack(spacing: 8) {
                Text(Self.shortDate(day.key))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let relative = Self.relativeLabel(day.key) {
                    Text(relative)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.hudMint)
                }
                Spacer(minLength: 0)
                // Only worth saying when a date is split across files, which
                // happens after a path-template change. Two files, one day.
                if day.files.count > 1 {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("This day is spread over \(day.files.count) files")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.6))
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dates

    private func step(by months: Int) {
        guard let moved = calendar.date(byAdding: .month, value: months, to: shell.visibleMonth) else { return }
        shell.visibleMonth = moved
    }

    /// Every month that has an entry, newest first — the month menu's contents.
    private var monthsWithEntries: [Date] {
        var seen: Set<String> = []
        var months: [Date] = []
        for day in store.days {
            let prefix = String(day.key.prefix(7))
            guard !seen.contains(prefix), let date = JournalStore.date(for: day.key) else { continue }
            seen.insert(prefix)
            if let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) {
                months.append(start)
            }
        }
        return months
    }

    /// The visible month, padded at the front so the 1st lands under the right
    /// weekday. `firstWeekday` comes from the user's own calendar, so a week
    /// starts on Monday or Sunday as their Mac says it does.
    private var gridDates: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: shell.visibleMonth) else { return [] }
        let first = interval.start
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 0
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        // Pad to whole weeks so the grid doesn't reflow as months change length.
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(start + $0) % 7] }
    }

    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private static func shortDate(_ key: String) -> String {
        guard let date = JournalStore.date(for: key) else { return key }
        return shortDateFormatter.string(from: date)
    }

    /// "Today" / "Yesterday", or nothing.
    static func relativeLabel(_ key: String) -> String? {
        guard let date = JournalStore.date(for: key) else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return nil
    }
}
