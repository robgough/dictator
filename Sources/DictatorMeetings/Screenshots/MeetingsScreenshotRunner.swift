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

    /// The meeting the shots open on — the same fixture Demo mode features.
    static let featuredID = MeetingsDemoFixtures.featuredID

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
    //
    // The fixture *data* lives in `MeetingsDemoFixtures`, shared with the
    // user-facing Demo mode so a marketing shot and a screen recording can
    // never drift apart. This file keeps only the screenshot-specific staging.

    private static let sam = MeetingsDemoFixtures.sam
    private static let priya = MeetingsDemoFixtures.priya
    private static let tom = MeetingsDemoFixtures.tom

    private static func fixtureMetas() -> [MeetingMeta] {
        MeetingsDemoFixtures.metas()
    }

    private static func featuredTranscript() -> MeetingTranscript {
        MeetingsDemoFixtures.featuredTranscript()
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
