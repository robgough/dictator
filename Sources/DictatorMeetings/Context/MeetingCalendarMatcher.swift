import EventKit
import Foundation

/// Matches a recording to its calendar event: the event overlapping (or
/// starting nearest to) the recording's start, preferring real meetings
/// (has attendees) over solo blocks. The 80/20 of "who am I meeting and
/// what about" — attendee emails carry names and companies that no amount
/// of vision or transcript inference recovers as reliably.
///
/// Permission: full calendar access, requested on first use. Denial is
/// silent and final for the session — no banners, the meeting simply
/// carries no calendar context.
@MainActor
enum MeetingCalendarMatcher {
    /// How far either side of the recording start to look.
    private static let windowSeconds: TimeInterval = 20 * 60

    static func match(recordingStart: Date) async -> MeetingCalendarContext? {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else { return nil }
        default:
            return nil
        }

        let predicate = store.predicateForEvents(
            withStart: recordingStart.addingTimeInterval(-windowSeconds),
            end: recordingStart.addingTimeInterval(windowSeconds),
            calendars: nil
        )
        let candidates = store.events(matching: predicate).filter { event in
            guard !event.isAllDay else { return false }
            guard let start = event.startDate, let end = event.endDate else { return false }
            // Overlapping the start, or starting within the window — covers
            // joining a few minutes early.
            return end > recordingStart || abs(start.timeIntervalSince(recordingStart)) <= windowSeconds
        }
        guard !candidates.isEmpty else { return nil }

        // Closest start wins; an event with attendees beats a solo block at
        // similar distance (your "focus time" shouldn't shadow the real call).
        let best = candidates.min { a, b in
            score(a, recordingStart: recordingStart) < score(b, recordingStart: recordingStart)
        }
        guard let event = best, let start = event.startDate, let end = event.endDate else { return nil }

        let attendees: [MeetingCalendarContext.Attendee] = (event.attendees ?? []).compactMap { participant in
            guard participant.participantType == .person else { return nil }
            return MeetingCalendarContext.Attendee(
                name: participant.name,
                email: Self.email(from: participant.url)
            )
        }

        return MeetingCalendarContext(
            title: event.title ?? "Meeting",
            startDate: start,
            endDate: end,
            calendarTitle: event.calendar?.title,
            organizerName: event.organizer?.name,
            attendees: attendees
        )
    }

    private static func score(_ event: EKEvent, recordingStart: Date) -> Double {
        let distance = abs((event.startDate ?? .distantPast).timeIntervalSince(recordingStart))
        // Attendee-less events pay a 10-minute handicap.
        let soloPenalty: Double = (event.attendees?.isEmpty ?? true) ? 600 : 0
        return distance + soloPenalty
    }

    private static func email(from url: URL?) -> String? {
        guard let url else { return nil }
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(raw.dropFirst("mailto:".count))
            .removingPercentEncoding ?? String(raw.dropFirst("mailto:".count))
        return address.isEmpty ? nil : address
    }
}
