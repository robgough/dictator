import AppKit
import EventKit
import Observation

/// The next meetings on the user's calendar, for the Today screen, and the
/// "Record when it starts" arm.
///
/// Read-only and on demand: the Today screen asks for a refresh when it
/// appears and when the calendar database changes. Honours the same setting
/// as the calendar matching that names recordings — someone who turned the
/// calendar off shouldn't find the app reading it anyway.
@MainActor
@Observable
final class UpcomingMeetings {
    static let shared = UpcomingMeetings()

    struct Event: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendeeCount: Int
        /// "Zoom", "Teams", "Google Meet" when the event carries a join link.
        let joinService: String?
        let joinURL: URL?
    }

    enum Access { case unknown, granted, denied, off }

    private(set) var events: [Event] = []
    private(set) var access: Access = .unknown

    /// The event whose start will begin a recording, if any. Held in memory
    /// only: arming is a decision about today, not a standing setting.
    private(set) var armedEventID: String?
    @ObservationIgnored private var armTimer: Timer?
    @ObservationIgnored private var changeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let store = EKEventStore()
    /// Set by a screenshot run, which has no calendar to read.
    @ObservationIgnored private var usingFixture = false

    private init() {}

    /// The first event that hasn't finished yet — the one Today leads with.
    var next: Event? { events.first }

    func refresh(settings: MeetingsSettings) async {
        if usingFixture { return }
        guard settings.meetingCalendarMatchingEnabled else {
            access = .off
            events = []
            return
        }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            access = .unknown
            events = []
            return
        default:
            access = .denied
            events = []
            return
        }
        observeChanges(settings: settings)
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: horizon, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && ($0.endDate ?? now) > now && $0.status != .canceled }
            .sorted { ($0.startDate ?? now) < ($1.startDate ?? now) }
            .prefix(5)
            .compactMap(Self.makeEvent)
        // An armed event that's gone from the calendar can't start anything.
        if let armed = armedEventID, !events.contains(where: { $0.id == armed }) {
            disarm()
        }
    }

    /// Asks for calendar access — only ever from a button the user pressed.
    func requestAccess(settings: MeetingsSettings) async {
        _ = try? await store.requestFullAccessToEvents()
        await refresh(settings: settings)
    }

    /// Screenshot mode only: stand-in events for a capture.
    func applyScreenshotFixture(_ fixture: [Event]) {
        guard ScreenshotMode.isActive else { return }
        usingFixture = true
        access = .granted
        events = fixture
    }

    // MARK: - Record when it starts

    /// Start recording when `event` begins. Fires through the same one-shot
    /// request the menu bar's Record Meeting uses, so it goes through every
    /// gate a click would (models, permissions, a recording already running)
    /// and works with the window closed — opening it is part of the request.
    func arm(_ event: Event) {
        disarm()
        armedEventID = event.id
        let delay = max(0, event.start.timeIntervalSinceNow)
        let eventID = event.id
        armTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.armedEventID == eventID else { return }
                self.disarm()
                let state = MeetingsAppState.shared
                state.pendingMeetingRecording = true
                state.openMeetingsWindowAction?()
            }
        }
    }

    func disarm() {
        armTimer?.invalidate()
        armTimer = nil
        armedEventID = nil
    }

    // MARK: - Private

    private func observeChanges(settings: MeetingsSettings) {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(settings: MeetingsAppState.shared.settings) }
            }
        }
    }

    private static func makeEvent(_ event: EKEvent) -> Event? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let haystack = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }.joined(separator: " ")
        let (service, url) = joinLink(in: haystack)
        let people = (event.attendees ?? []).filter { $0.participantType == .person }
        return Event(
            id: event.calendarItemIdentifier + "@\(Int(start.timeIntervalSince1970))",
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            start: start,
            end: end,
            attendeeCount: people.count,
            joinService: service,
            joinURL: url)
    }

    private static func joinLink(in text: String) -> (String?, URL?) {
        let services: [(String, String)] = [
            ("zoom.us/", "Zoom"),
            ("teams.microsoft.com", "Teams"),
            ("meet.google.com", "Google Meet"),
            ("webex.com", "Webex"),
        ]
        for (needle, name) in services where text.contains(needle) {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let ns = text as NSString
            let url = detector?.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .compactMap(\.url)
                .first { $0.absoluteString.contains(needle) }
            return (name, url)
        }
        return (nil, nil)
    }
}
