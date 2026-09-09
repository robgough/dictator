import Foundation

/// Fictional meetings, notes, transcripts, pads and people — used wherever
/// Dictator Meetings has to show "the user's own stuff" without showing the
/// *actual* user's stuff: developer-only screenshot mode
/// (`MeetingsScreenshotRunner`) and the user-facing Demo mode
/// (`MeetingsDemoMode`).
///
/// One cast, one set of facts, one place to change them — the two features
/// would otherwise drift apart and a marketing shot would stop matching what a
/// recording shows. Mirrors `DemoFixtures` on the Dictator side, and shares its
/// cast so the two apps tell one story: **Sam Okafor** (the user), **Priya
/// Natarajan** and **Tom Reilly** (colleagues at Lumenfield), **Dana
/// Whitfield** (the client contact at Northwind). No real names, no real
/// domains — `.example` is reserved by RFC 2606 and can never resolve.
///
/// Nothing here is ever written into a real store: screenshot mode runs against
/// a throwaway data root, and demo mode materialises these into a temp folder
/// that `MeetingStorage` redirects fixture ids to (see `MeetingsDemoMode`).
@MainActor
enum MeetingsDemoFixtures {

    static let userName = "Sam Okafor"

    /// The meeting the screenshots open on, and the richest of the fixtures —
    /// notes, transcript, coach report, calendar context and a pad.
    static let featuredID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!

    /// Stable ids for the five supporting meetings, so a fixture's folder,
    /// transcript and pad all agree across a switch-on.
    static func supportingID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "A1B2C3D4-0000-4000-8000-%012d", n))!
    }

    // MARK: - Cast

    /// People-store ids. Fixed strings so `speakers[].personID` links to the
    /// fixture people the People editor shows.
    static let priyaPersonID = "D0000000-0000-4000-8000-000000000001"
    static let tomPersonID = "D0000000-0000-4000-8000-000000000002"
    static let danaPersonID = "D0000000-0000-4000-8000-000000000003"

    static let sam = MeetingMeta.Speaker(
        id: "me", displayName: "Sam Okafor", colorHex: "#5B9BD5", isMe: true)
    static let priya = MeetingMeta.Speaker(
        id: "speaker_1", displayName: "Priya Natarajan", colorHex: "#ED7D31",
        nameInferred: true, personID: priyaPersonID)
    static let tom = MeetingMeta.Speaker(
        id: "speaker_2", displayName: "Tom Reilly", colorHex: "#7E57C2",
        nameInferred: true, personID: tomPersonID)
    static let dana = MeetingMeta.Speaker(
        id: "speaker_3", displayName: "Dana Whitfield", colorHex: "#4CAF7D",
        nameInferred: true, personID: danaPersonID)

    // MARK: - Meetings

    /// Six finished meetings, newest first-ish (the store sorts them): one
    /// fully-worked planning call plus five that fill the sidebar's date
    /// groups with a plausible week.
    ///
    /// Dates are relative to "now" whenever the fixtures are built, so the
    /// sidebar always shows Today / Yesterday / Previous 7 Days sections
    /// rather than a stale block under "Earlier".
    static func metas() -> [MeetingMeta] {
        let audio = MeetingMeta.AudioFiles(
            mic: MeetingStorage.micFilename, system: MeetingStorage.systemFilename)

        let featured = MeetingMeta(
            id: featuredID,
            title: "Q3 roadmap sync",
            createdAt: date(daysAgo: 0, hour: 10, minute: 5),
            durationSeconds: 38 * 60 + 12,
            source: .live,
            audioFiles: audio,
            speakers: [sam, priya, tom],
            notes: MeetingNotes(
                markdown: featuredNotesMarkdown,
                modelID: "qwen3-8b-mlx",
                generatedAt: date(daysAgo: 0, hour: 10, minute: 45),
                isFinal: true,
                meetingType: .planning,
                meetingTypeWasDetected: true
            ),
            meetingType: .planning,
            coach: featuredCoach,
            sourceApp: MeetingSourceApp(bundleID: "us.zoom.xos", name: "Zoom"),
            calendar: MeetingCalendarContext(
                title: "Q3 roadmap sync",
                startDate: date(daysAgo: 0, hour: 10, minute: 0),
                endDate: date(daysAgo: 0, hour: 10, minute: 45),
                calendarTitle: "Work",
                organizerName: "Priya Natarajan",
                attendees: [
                    .init(name: "Sam Okafor", email: "sam@lumenfield.example"),
                    .init(name: "Priya Natarajan", email: "priya@lumenfield.example"),
                    .init(name: "Tom Reilly", email: "tom@lumenfield.example"),
                ]
            )
        )

        return [
            featured,
            supporting(
                2, "Northwind renewal call", date(daysAgo: 0, hour: 8, minute: 30), 26,
                [sam, priya, dana],
                summary: "Northwind will renew for twelve months at the current tier, with a decision on the extra seats by the end of the month.",
                actions: [
                    "**Sam** — send the renewal paperwork over today.",
                    "**Priya** — price up the five extra seats before Friday.",
                ],
                type: .clientCall
            ),
            supporting(
                3, "Weekly 1-on-1 — Tom", date(daysAgo: 1, hour: 15, minute: 0), 31,
                [sam, tom],
                summary: "Tom is unblocked on the importer and wants a week on the flaky upload tests before taking anything new on.",
                actions: [
                    "**Tom** — a week on the upload tests, then pick up the export work.",
                    "**Sam** — take the on-call swap to the team so it isn't Tom's problem alone.",
                ],
                type: .oneOnOne
            ),
            supporting(
                4, "Design review: onboarding flow", date(daysAgo: 1, hour: 11, minute: 15), 47,
                [sam, priya, tom],
                summary: "The three-step onboarding tested well; the permission screen still needs a plain-language rewrite before it ships.",
                actions: [
                    "**Priya** — rewrite the permission screen in plain language.",
                    "**Sam** — book a second round of five trial users for next week.",
                ],
                type: .teamMeeting
            ),
            supporting(
                5, "Interview — platform engineer", date(daysAgo: 3, hour: 14, minute: 0), 52,
                [sam, priya],
                summary: "Strong systems answers and a clear worked example of an incident they led. Recommend a follow-up with the platform team.",
                actions: [
                    "**Sam** — write the scorecard up today while it's fresh.",
                    "**Priya** — arrange the platform-team follow-up.",
                ],
                type: .interview
            ),
            supporting(
                6, "Support triage stand-up", date(daysAgo: 6, hour: 9, minute: 15), 14,
                [sam, tom],
                summary: "Two escalations carried over; the sync backlog is down to nine tickets and the rota is covered until Friday.",
                actions: [
                    "**Tom** — close out the two carried-over escalations.",
                ],
                type: .standup
            ),
        ]
    }

    private static func supporting(
        _ id: Int,
        _ title: String,
        _ createdAt: Date,
        _ minutes: Int,
        _ speakers: [MeetingMeta.Speaker],
        summary: String,
        actions: [String],
        type: MeetingTypeID
    ) -> MeetingMeta {
        let body = "## Summary\n\(summary)\n\n## Action items\n"
            + actions.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return MeetingMeta(
            id: supportingID(id),
            title: title,
            createdAt: createdAt,
            durationSeconds: Double(minutes) * 60,
            source: .live,
            audioFiles: MeetingMeta.AudioFiles(
                mic: MeetingStorage.micFilename, system: MeetingStorage.systemFilename),
            speakers: speakers,
            notes: MeetingNotes(
                markdown: body,
                modelID: "qwen3-8b-mlx",
                generatedAt: createdAt.addingTimeInterval(Double(minutes) * 60 + 300),
                isFinal: true
            ),
            meetingType: type
        )
    }

    /// `daysAgo` back from today, at a fixed wall-clock time — keeps a
    /// fixture's sidebar group ("Today", "Yesterday") right whenever it's built
    /// while the times stay plausible working hours.
    static func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - Notes, coach

    static let featuredNotesMarkdown = """
    ## Summary

    Sam, Priya and Tom cut the Q3 roadmap from five themes to two — the onboarding \
    rebuild and the import pipeline — after agreeing that everything else depended on \
    hiring that hasn't happened yet. Reporting slips to Q4 with a lightweight export \
    in the meantime, and the team will re-check scope at the end of month one.

    ## Discussion

    ### Scope for the quarter
    - Five themes on the draft plan needed roughly nine engineers; the team has five.
    - Priya argued for finishing onboarding properly rather than starting reporting, \
    since half of the trial drop-off happens on the permission screen.
    - Tom's importer work is already half done and blocks two customer commitments, so \
    it stays in.

    ### Reporting
    - Reporting moves to Q4. The two customers asking for it are satisfied by a CSV \
    export, which Tom estimates at three days rather than three weeks.
    - Nobody wanted to build the dashboard twice, and the data model changes with the \
    import work.

    ### Hiring
    - The second backend role is still open; Priya will chase the recruiter this week.
    - The plan assumes no new starters land before September.

    ## Decisions

    - Q3 ships two themes: the onboarding rebuild and the import pipeline.
    - Reporting is deferred to Q4, with a CSV export as the stop-gap.
    - Scope gets re-checked at the end of month one, not at the end of the quarter.

    ## Action items

    - **Priya** — rewrite the permission screen copy and put it in front of five trial \
    users, by Friday.
    - **Tom** — scope the CSV export and confirm the three-day estimate, by Wednesday.
    - **Sam** — send the revised one-page plan to the wider team and book the month-one \
    scope check.
    - **Priya** — chase the recruiter on the second backend role this week.
    """

    static var featuredCoach: MeetingCoachResult {
        MeetingCoachResult(
            metrics: CoachMetrics(
                myTalkSeconds: 1_063,
                theirTalkSeconds: 770,
                talkShareMe: 0.58,
                longestMonologueSeconds: 214,
                interruptionsByMe: 3,
                paceWordsPerMinute: 168,
                fillerWordsPerMinute: 2.4,
                fillerWordCount: 43,
                myQuestionCount: 6,
                longestSilenceSeconds: 19
            ),
            generatedAt: date(daysAgo: 0, hour: 10, minute: 45),
            checklist: [
                CoachChecklistOutcome(source: "preset",
                                      text: "Get a decision on what drops from the quarter",
                                      addedAtSeconds: 0, doneAtSeconds: 742),
                CoachChecklistOutcome(source: "preset",
                                      text: "Agree who owns the onboarding rebuild",
                                      addedAtSeconds: 0, doneAtSeconds: 1_508),
                CoachChecklistOutcome(source: "adhoc",
                                      text: "Ask Tom about cover for the August support rota",
                                      addedAtSeconds: 610, doneAtSeconds: nil),
            ],
            presetTypeID: "planning",
            reportMarkdown: """
            You took 58% of the airtime in a meeting whose whole purpose was to hear \
            what Priya and Tom thought had to go — and your longest single run was three \
            and a half minutes, right at the point where you were arguing for keeping \
            reporting. The decisions landed, but you cut in three times and you never \
            got back to the August rota you flagged yourself at minute ten.
            """,
            reportGeneratedAt: date(daysAgo: 0, hour: 10, minute: 46),
            reportModelID: "qwen3-8b-mlx"
        )
    }

    // MARK: - Transcripts

    /// Every fixture transcript, keyed by meeting. Demo mode writes all of
    /// them; screenshot mode only needs the featured one.
    static func transcripts() -> [UUID: MeetingTranscript] {
        [
            featuredID: featuredTranscript(),
            supportingID(2): transcript(northwindTurns),
            supportingID(3): transcript(oneOnOneTurns),
            supportingID(4): transcript(designReviewTurns),
            supportingID(5): transcript(interviewTurns),
            supportingID(6): transcript(standupTurns),
        ]
    }

    static func featuredTranscript() -> MeetingTranscript {
        transcript(featuredTurns)
    }

    /// Lay a list of (speaker, line) turns out on a timeline at a natural
    /// speaking pace, with a beat between each. Deterministic apart from the
    /// gaps, which only affect the timestamps shown beside each line.
    private static func transcript(_ turns: [(String, String)]) -> MeetingTranscript {
        var segments: [MeetingTranscriptSegment] = []
        var t: Double = 12
        for (speaker, text) in turns {
            let words = Double(text.split(separator: " ").count)
            let duration = max(4, words / 2.8)
            segments.append(MeetingTranscriptSegment(
                start: t, end: t + duration, speakerId: speaker, text: text))
            t += duration + Double.random(in: 1.5...4.5)
        }
        return MeetingTranscript(segments: segments)
    }

    private static let featuredTurns: [(String, String)] = [
        ("me", "Right — before we get into the detail, the plan as drafted needs about nine engineers and we have five."),
        ("speaker_1", "That's the whole conversation, isn't it. Something has to come off."),
        ("speaker_2", "Two of them are half-built already, so it depends which two you cut."),
        ("me", "Agreed. Priya, you've been closest to the trial numbers — where does the drop-off actually happen?"),
        ("speaker_1", "The permission screen. Just under half the people who abandon never get past it."),
        ("speaker_1", "So if we're honest, finishing onboarding properly is worth more than starting reporting."),
        ("me", "That's fair. Tom, where's the importer?"),
        ("speaker_2", "About half done, and it's blocking the two commitments we made in June, so I'd rather not park it."),
        ("me", "Then that's two themes: onboarding and import. Which means reporting slips."),
        ("speaker_1", "Who's actually asking for reporting?"),
        ("me", "Two customers. Both of them would be satisfied by an export, I think."),
        ("speaker_2", "A CSV export is three days. The dashboard is three weeks and I'd be building it twice, because the data model moves under the import work."),
        ("speaker_1", "Then it's not really a trade-off. Export now, dashboard in Q4."),
        ("me", "Let's say that's decided. Reporting moves to Q4 with a CSV export as the stop-gap."),
        ("speaker_2", "I'll scope the export properly and confirm the three days by Wednesday."),
        ("me", "Thanks. On onboarding — who owns it end to end?"),
        ("speaker_1", "I'll take it. I want to rewrite the permission copy first and put it in front of five trial users."),
        ("me", "Good. Friday?"),
        ("speaker_1", "Friday."),
        ("speaker_2", "Does the plan assume any new starters?"),
        ("me", "No. It assumes nobody lands before September."),
        ("speaker_1", "The second backend role is still sitting with the recruiter. I'll chase it this week."),
        ("me", "One more thing — I'd rather not wait until the end of the quarter to find out we were wrong."),
        ("me", "Let's re-check scope at the end of month one. I'll book it and send the revised one-pager round."),
        ("speaker_1", "That works."),
        ("speaker_2", "Same."),
    ]

    private static let northwindTurns: [(String, String)] = [
        ("me", "Thanks for making the time, Dana. The short version is we'd like to roll you over for another twelve months on the same tier."),
        ("speaker_3", "That's what I assumed. The team have been happy since the import work landed — nobody's complained at me for a month, which is the highest praise I give."),
        ("speaker_1", "The extra seats are the open question. You mentioned five in the spring."),
        ("speaker_3", "Five is still the number, but I can't sign for them until the new headcount is confirmed. End of the month, realistically."),
        ("me", "Then let's not hold the renewal up for it. Same tier now, seats as a separate line when you know."),
        ("speaker_3", "That works. Send the paperwork and I'll get it in front of legal this week."),
        ("speaker_1", "I'll price the five seats up anyway so it's ready when you are."),
        ("speaker_3", "Appreciated. Nothing else from me."),
    ]

    private static let oneOnOneTurns: [(String, String)] = [
        ("me", "How's the importer looking now the schema change is in?"),
        ("speaker_2", "Unblocked. It was the dry-run mode that was fighting me, and that's done, so it's just grind from here."),
        ("me", "Good. What do you want to pick up next?"),
        ("speaker_2", "Honestly? A week on the upload tests. They fail about one run in six and everyone's learned to just re-run them, which is how you end up ignoring a real failure."),
        ("me", "Take the week. I'd rather that than a third person losing an afternoon to it."),
        ("speaker_2", "The other thing is on-call. I've had the last two swaps and I'd like it to go back round the team."),
        ("me", "That's fair, and it's mine to fix rather than yours. I'll take it to the team on Thursday."),
        ("speaker_2", "Then I'm happy."),
    ]

    private static let designReviewTurns: [(String, String)] = [
        ("speaker_1", "Three steps, and we tested it with five people yesterday. Four of them got through without a word from me."),
        ("me", "And the fifth?"),
        ("speaker_1", "Stopped dead on the permission screen. Read it twice, then asked me what it was going to do with her microphone."),
        ("speaker_2", "That's the screen we wrote from the entitlement descriptions, isn't it."),
        ("speaker_1", "It is, and it reads like it. It needs writing in plain language — what we ask for, when, and what happens if you say no."),
        ("me", "Then that's the one blocker. The rest of the flow ships as it is."),
        ("speaker_1", "I'll have new copy by the end of the week and we can run another five."),
        ("me", "Book them in for next week and we'll look at it together."),
    ]

    private static let interviewTurns: [(String, String)] = [
        ("me", "Tell us about something that broke badly and what you did about it."),
        ("speaker_1", "The one I always come back to is a queue that silently dropped messages under load for about six weeks before anyone noticed."),
        ("me", "How did you find it?"),
        ("speaker_1", "A customer told us. Which is the worst way to find out, and it's the reason I now care so much about counting what goes in against what comes out."),
        ("me", "What did you change afterwards?"),
        ("speaker_1", "Reconciliation counts on every hop and an alert on the difference. It caught two smaller versions of the same bug the year after."),
        ("me", "Last one: what would you want from your first month here?"),
        ("speaker_1", "Something small shipped end to end in the first fortnight. I don't learn a system by reading it."),
    ]

    private static let standupTurns: [(String, String)] = [
        ("me", "Two escalations carried over from Friday. Where are they?"),
        ("speaker_2", "Both waiting on customer logs. I've chased once; I'll chase again this morning and close them out either way by tomorrow."),
        ("me", "And the sync backlog?"),
        ("speaker_2", "Down to nine from twenty-three. Most of them were the same duplicate-account thing, so the fix took a lot out at once."),
        ("me", "Rota for the rest of the week?"),
        ("speaker_2", "Covered through Friday. Next week has a hole on Wednesday that I'll sort today."),
    ]

    // MARK: - Pads

    /// The user's own typed notes, per meeting. Only a couple of the fixtures
    /// have one — most meetings don't, and an empty Pad tab is the honest
    /// default.
    static func pads() -> [UUID: String] {
        [
            featuredID: """
            Before the call
            - Don't open with the headcount argument, let Priya get there
            - Ask Tom for the real importer estimate, not the safe one
            - August rota — needs cover for the 12th–16th

            During
            - Priya: permission copy → 5 trial users, Friday
            - Tom: CSV export estimate by Wednesday
            - Book the month-one scope check
            """,
            supportingID(2): """
            Renewal: same tier, 12 months
            Seats — 5, blocked on their headcount, decide end of month
            Paperwork → their legal this week
            """,
        ]
    }

    // MARK: - People

    /// Who the demo user has met with, as the People editor shows them:
    /// names, emails, and a plausible number of remembered voice samples.
    /// The embedding vectors are inert filler — the demo overlay is never
    /// matched against, only listed.
    static func people() -> [PersonRecord] {
        [
            person(id: priyaPersonID, name: "Priya Natarajan",
                   emails: ["priya@lumenfield.example"], samples: 6, daysAgo: 41),
            person(id: tomPersonID, name: "Tom Reilly",
                   emails: ["tom@lumenfield.example"], samples: 4, daysAgo: 33),
            person(id: danaPersonID, name: "Dana Whitfield",
                   emails: ["dana@northwind.example"], samples: 2, daysAgo: 9),
        ]
    }

    private static func person(
        id: String, name: String, emails: [String], samples: Int, daysAgo: Int
    ) -> PersonRecord {
        PersonRecord(
            id: id,
            name: name,
            emails: emails,
            embeddings: Array(repeating: [Float](repeating: 0, count: 4), count: samples),
            embeddingModelID: "pyannote-segmentation-3.0",
            createdAt: date(daysAgo: daysAgo, hour: 11, minute: 0),
            updatedAt: date(daysAgo: 0, hour: 10, minute: 45)
        )
    }
}
