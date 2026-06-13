import Foundation

/// Which app the meeting ran in — detected from the audio-process list (who
/// was actually emitting call audio) with the frontmost app as tiebreaker.
struct MeetingSourceApp: Codable, Equatable, Sendable {
    var bundleID: String
    var name: String

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// The calendar event a recording matched, captured at record time so the
/// meeting carries its real subject, attendees, and scheduled span. All
/// fields are snapshots — later calendar edits don't rewrite history.
struct MeetingCalendarContext: Codable, Equatable, Sendable {
    struct Attendee: Codable, Equatable, Sendable {
        var name: String?
        var email: String?

        init(name: String?, email: String?) {
            self.name = name
            self.email = email
        }
    }

    var title: String
    var startDate: Date
    var endDate: Date
    var calendarTitle: String?
    var organizerName: String?
    var attendees: [Attendee]

    init(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarTitle: String? = nil,
        organizerName: String? = nil,
        attendees: [Attendee] = []
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarTitle = calendarTitle
        self.organizerName = organizerName
        self.attendees = attendees
    }

    /// Distinct organisation domains among the attendees — freemail and
    /// calendar-plumbing domains dropped, so "two people from acme.com"
    /// surfaces and "gmail.com" doesn't.
    var companyDomains: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for attendee in attendees {
            guard let email = attendee.email,
                  let at = email.lastIndex(of: "@") else { continue }
            let domain = email[email.index(after: at)...].lowercased()
            guard !domain.isEmpty,
                  !Self.freemailDomains.contains(domain),
                  !domain.hasSuffix("calendar.google.com"),
                  !seen.contains(domain) else { continue }
            seen.insert(domain)
            out.append(domain)
        }
        return out
    }

    private static let freemailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "yahoo.co.uk", "proton.me", "protonmail.com",
        "fastmail.com", "fastmail.fm", "hey.com", "aol.com", "gmx.com",
    ]
}
