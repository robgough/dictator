import EventKit

/// Which of the user's calendars the app reads. One place for the exclusion
/// list, so Today's "up next" and the recording matcher can't disagree about
/// which calendars count.
@MainActor
enum MeetingCalendars {
    /// The calendars to search, or nil when every calendar was excluded —
    /// in which case there's nothing to read. (Never hand EventKit an empty
    /// list: whether that means "none" or "all" isn't documented.)
    static func included(in store: EKEventStore, settings: MeetingsSettings) -> [EKCalendar]? {
        let excluded = Set(settings.meetingExcludedCalendarIDs)
        let calendars = store.calendars(for: .event).filter { !excluded.contains($0.calendarIdentifier) }
        return calendars.isEmpty ? nil : calendars
    }

    /// Every event calendar, grouped by account, for the picker.
    struct Group: Identifiable {
        let id: String
        let title: String
        let calendars: [EKCalendar]
    }

    static func grouped(in store: EKEventStore) -> [Group] {
        let bySource = Dictionary(grouping: store.calendars(for: .event)) { $0.source?.sourceIdentifier ?? "" }
        return bySource.map { id, calendars in
            Group(
                id: id,
                title: calendars.first?.source?.title ?? "Other",
                calendars: calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
