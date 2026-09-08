import AppKit
import SwiftUI

/// Developer-only screenshot mode for Dictator Meetings. See `ScreenshotMode`
/// (DictatorCore) for the environment contract and `scripts/mac-screenshots.sh`
/// for the driver.
///
/// Three shots: `live-recording` (mid-call), `notes` and `coach` (a finished
/// meeting). Fixtures are written to the throwaway data root as ordinary
/// `meta.json` / `transcript.json` files, so the app loads them through the
/// normal `MeetingsStore` path rather than through a UI back door. Everything
/// in here is fictional — no real person, client or meeting appears.
///
/// Entered from `AppDelegate.applicationDidFinishLaunching` ahead of the
/// single-instance guard, so the capture runs alongside the user's installed
/// copy without quitting or disturbing it, and never reaches `bootstrap()`:
/// no model preload, no aggregate-device sweep, no provider warm-up.
@MainActor
enum MeetingsScreenshotRunner {

    /// Window size for this shot. The width is fixed and generous: the
    /// sidebar, the detail column and the Details inspector all have minimums,
    /// and below their sum AppKit's constraint negotiation never settles (the
    /// app aborts). Heights are per-shot so each capture is filled with
    /// content rather than trailing empty space.
    static var windowSize: NSSize {
        switch ScreenshotMode.shot {
        case "coach":          return NSSize(width: 1360, height: 528)
        case "live-recording": return NSSize(width: 1360, height: 980)
        default:               return NSSize(width: 1360, height: 860)
        }
    }

    /// The meeting the shots open on. Fixed id so `seed()` and `configure` agree.
    static let featuredID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!

    /// Which detail tab `TranscriptView` should open on for this shot.
    static var detailTab: String? {
        switch ScreenshotMode.shot {
        case "coach": return "coach"
        case "notes": return "notes"
        default: return nil
        }
    }

    // MARK: - Entry points

    /// Write the fixture meetings. Called from `DictatorMeetingsApp.init` right
    /// after `prepareStorage()`, i.e. before the window's first store scan.
    static func seed() {
        guard ScreenshotMode.isActive else { return }
        // Fresh throwaway settings would otherwise raise the first-run
        // onboarding sheet, which takes key-window status and dims the whole
        // window behind it.
        // Three bits of window state live in `UserDefaults.standard` — which,
        // for an unsigned capture build sharing the installed app's bundle id,
        // is the user's real preference domain. Override them in the in-memory
        // argument domain (highest precedence, never written to disk) rather
        // than reading or writing that:
        //
        //  - the Details inspector's `@AppStorage` visibility flag;
        //  - the window's restored frame — the app aborts during layout if the
        //    window opens too narrow to satisfy sidebar + detail + inspector
        //    minimums at once (the documented Update-Constraints blow-up);
        //  - the saved sidebar width, for the same reason.
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        UserDefaults.standard.setVolatileDomain([
            "meetingsInspectorVisible": true,
            "NSWindow Frame meetings":
                "160 140 \(Int(windowSize.width)) \(Int(windowSize.height)) 0 0 \(Int(screen.width)) \(Int(screen.height)) ",
            "NSSplitView Subview Frames meetings, SidebarNavigationSplitView": [],
        ], forName: UserDefaults.argumentDomain)
        let state = MeetingsAppState.shared
        state.settings.hasCompletedOnboarding = true
        state.settings.showMenuBarStatus = false
        state.settings.meetingLiveTranscriptEnabled = true
        state.settings.meetingLiveNotesEnabled = true
        state.settings.meetingCoachEnabled = true
        for meta in fixtureMetas() {
            try? MeetingStorage.writeMeta(meta)
        }
        try? MeetingStorage.writeTranscript(featuredTranscript(), for: featuredID)
        // Re-write the featured meta so `notes.md` / `transcript.md` mirrors are
        // regenerated now the transcript exists.
        if let featured = fixtureMetas().first(where: { $0.id == featuredID }) {
            try? MeetingStorage.writeMeta(featured)
        }
        MeetingsStore.shared.refresh()
    }

    /// Hand the root view's selection + live-session state to the runner, so a
    /// shot can open on a specific meeting or on a fabricated live recording.
    static func configure(selection: Binding<UUID?>, liveSession: Binding<MeetingSession?>) {
        guard ScreenshotMode.isActive else { return }
        switch ScreenshotMode.shot {
        case "notes", "coach":
            selection.wrappedValue = featuredID
        case "live-recording":
            liveSession.wrappedValue = liveFixtureSession()
        default:
            break
        }
    }

    /// Render the window and exit.
    static func run() {
        ScreenshotWindowCapture.startWatchdog(seconds: 30)
        ScreenshotWindowCapture.forceLightAppearance()
        NSApp.setActivationPolicy(.regular)
        // Hop off the launch callback: AppKit only finishes activating the app
        // once it has returned, and an inactive app renders inactive chrome.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { perform() }
    }

    private static func perform() {
        // The window scene needs a beat to build the split view, the detail
        // pane and the inspector.
        ScreenshotWindowCapture.settle(seconds: 2.0)
        guard let window = ScreenshotWindowCapture.window(where: { $0.title == "Meetings" })
                ?? ScreenshotWindowCapture.window(where: { $0.contentView != nil && $0.styleMask.contains(.titled) })
        else {
            NSLog("[Screenshot] No Meetings window")
            exit(1)
        }
        ScreenshotWindowCapture.place(window, size: windowSize)
        ScreenshotWindowCapture.activate(window)
        // Long settle: the live transcript animates in word by word
        // (TypewriterText) and the notes outline animates its bullets.
        ScreenshotWindowCapture.settle(seconds: ScreenshotMode.shot == "live-recording" ? 6.0 : 2.5)
        guard let path = ScreenshotMode.outputPath else {
            NSLog("[Screenshot] DICTATOR_SCREENSHOT_OUT unset")
            exit(1)
        }
        let size = ScreenshotWindowCapture.capture(window, to: path)
        ScreenshotWindowCapture.finish(size, path: path)
    }

    // MARK: - Finished-meeting fixtures

    private static func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static let sam = MeetingMeta.Speaker(
        id: "me", displayName: "Sam Okafor", colorHex: "#5B9BD5", isMe: true)
    private static let priya = MeetingMeta.Speaker(
        id: "speaker_1", displayName: "Priya Natarajan", colorHex: "#ED7D31", nameInferred: true)
    private static let tom = MeetingMeta.Speaker(
        id: "speaker_2", displayName: "Tom Reilly", colorHex: "#7E57C2", nameInferred: true)

    private static func fixtureMetas() -> [MeetingMeta] {
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

        func plain(_ id: Int, _ title: String, _ createdAt: Date, _ minutes: Int,
                   _ speakers: [MeetingMeta.Speaker], _ summary: String,
                   type: MeetingTypeID) -> MeetingMeta {
            MeetingMeta(
                id: UUID(uuidString: String(format: "A1B2C3D4-0000-4000-8000-%012d", id))!,
                title: title,
                createdAt: createdAt,
                durationSeconds: Double(minutes) * 60,
                source: .live,
                audioFiles: audio,
                speakers: speakers,
                notes: MeetingNotes(
                    markdown: "## Summary\n\(summary)\n",
                    modelID: "qwen3-8b-mlx",
                    generatedAt: createdAt.addingTimeInterval(Double(minutes) * 60 + 300),
                    isFinal: true
                ),
                meetingType: type
            )
        }

        return [
            featured,
            plain(2, "Northwind renewal call", date(daysAgo: 0, hour: 8, minute: 30), 26,
                  [sam, priya],
                  "Northwind will renew for twelve months at the current tier, with a decision on the extra seats by the end of the month.",
                  type: .clientCall),
            plain(3, "Weekly 1-on-1 — Tom", date(daysAgo: 1, hour: 15, minute: 0), 31,
                  [sam, tom],
                  "Tom is unblocked on the importer and wants a week on the flaky upload tests before taking anything new on.",
                  type: .oneOnOne),
            plain(4, "Design review: onboarding flow", date(daysAgo: 1, hour: 11, minute: 15), 47,
                  [sam, priya, tom],
                  "The three-step onboarding tested well; the permission screen still needs a plain-language rewrite before it ships.",
                  type: .teamMeeting),
            plain(5, "Interview — Priya Natarajan", date(daysAgo: 3, hour: 14, minute: 0), 52,
                  [sam, priya],
                  "Strong systems answers and a clear worked example of an incident she led. Recommend a follow-up with the platform team.",
                  type: .interview),
            plain(6, "Support triage stand-up", date(daysAgo: 6, hour: 9, minute: 15), 14,
                  [sam, tom],
                  "Two escalations carried over; the sync backlog is down to nine tickets and the rota is covered until Friday.",
                  type: .standup),
        ]
    }

    private static let featuredNotesMarkdown = """
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

    private static var featuredCoach: MeetingCoachResult {
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

    private static func featuredTranscript() -> MeetingTranscript {
        let turns: [(String, String)] = [
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

    // MARK: - Live-recording fixture

    private static func liveFixtureSession() -> MeetingSession {
        let session = MeetingSession(
            forLiveRecording: UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000FF")!,
            createdAt: Date().addingTimeInterval(-23 * 60 - 41)
        )
        session.meta.title = "Q3 planning call"
        session.meta.speakers = [sam, priya, tom]
        session.meta.meetingType = .planning

        let transcriber = MeetingLiveTranscriber(parakeetModelID: "parakeet-tdt-0.6b-v3")
        transcriber.applyScreenshotFixture(lines: [
            (MeetingLiveTranscriber.meLabel,
             "So the plan as drafted needs about nine engineers and we have five."),
            (MeetingLiveTranscriber.themLabel,
             "That's the whole conversation, isn't it. Something has to come off."),
            (MeetingLiveTranscriber.themLabel,
             "Two of them are half-built already, so it depends which two you cut."),
            (MeetingLiveTranscriber.meLabel,
             "Priya, you're closest to the trial numbers — where does the drop-off actually happen?"),
            (MeetingLiveTranscriber.themLabel,
             "The permission screen. Just under half the people who abandon never get past it."),
            (MeetingLiveTranscriber.meLabel,
             "Then finishing onboarding properly is worth more than starting reporting."),
            (MeetingLiveTranscriber.themLabel,
             "The importer is about half done and it blocks the two commitments we made in June."),
            (MeetingLiveTranscriber.meLabel,
             "Okay. So two themes — onboarding and import — and reporting slips to Q4."),
        ])

        let coach = MeetingCoachEngine(transcriber: transcriber, plan: nil)
        var snapshot = MeetingCoachSignals.Snapshot()
        snapshot.elapsed = 23 * 60 + 41
        snapshot.talkShareMe = 0.58
        snapshot.talkShareMeWindow = 0.61
        snapshot.myTalkSeconds = 604
        snapshot.theirTalkSeconds = 437
        snapshot.currentMonologueSeconds = 9
        snapshot.longestMonologueSeconds = 132
        snapshot.paceWordsPerMinute = 168
        snapshot.micActive = true
        snapshot.systemActive = false
        coach.applyScreenshotFixture(snapshot: snapshot, checklist: [
            CoachChecklistEntry(id: "preset-0",
                                text: "Get a decision on what drops from the quarter",
                                source: .preset, addedAtSeconds: 0, eligibleFromLine: 0,
                                status: .done(atSeconds: 742)),
            CoachChecklistEntry(id: "preset-1",
                                text: "Agree who owns the onboarding rebuild",
                                source: .preset, addedAtSeconds: 0, eligibleFromLine: 0,
                                status: .pending),
            CoachChecklistEntry(id: "adhoc-2",
                                text: "Ask Tom about cover for the August support rota",
                                source: .adhoc, addedAtSeconds: 610, eligibleFromLine: 4,
                                status: .pending),
        ])

        let notes = MeetingNotesAccumulator(
            transcriber: transcriber,
            settings: MeetingsAppState.shared.settings,
            coach: coach,
            notesEnabled: true
        )
        notes.applyScreenshotFixture(markdown: """
        ## Scope for the quarter
        - Draft plan needs ~9 engineers; the team has 5.
        - Onboarding drop-off is concentrated on the permission screen (just under half of abandons).
        - Importer is ~50% done and blocks two June commitments, so it stays in.

        ## Reporting
        - Two customers asking; a CSV export covers both.
        - Dashboard would be rebuilt once the import work moves the data model.

        ## Open
        - Who owns the onboarding rebuild end to end?
        """, lastUpdate: Date().addingTimeInterval(-14))

        session.applyScreenshotFixture(
            elapsed: 23 * 60 + 41,
            micLevel: 0.42,
            systemLevel: 0.18,
            transcriber: transcriber,
            notes: notes,
            coach: coach,
            pad: """
            Ask about the August rota
            Priya: permission copy → 5 trial users
            Confirm CSV export estimate
            Tom: importer ETA?
            Book the month-one scope check
            """
        )
        return session
    }
}
