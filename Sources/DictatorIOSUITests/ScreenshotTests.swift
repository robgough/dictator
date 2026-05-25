import XCTest

/// App Store screenshot automation.
///
/// Walks `DictatorIOS` through every UI state the App Store listing
/// needs — welcome, idle, mid-dictation, history, settings, keyboard
/// showcase — and attaches each screenshot to the test result bundle
/// so `scripts/extract-screenshots.sh` can copy them into
/// `screenshots/<size>/`.
///
/// Several states need pre-seeded state (onboarding flag, faked
/// recording status, keyboard mockup). Those run through the launch-
/// argument / environment-variable hooks in `DictatorIOSApp.init` and
/// `RecordingViewModel.init` rather than driving the UI directly —
/// faster and more reliable than chaining synthetic taps.
final class ScreenshotTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool { false }

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()

        // 1. Welcome — re-show the first-launch onboarding sheet via
        // the reset hook in `DictatorIOSApp.init`. The hook only flips
        // the persisted flag while the env var is set; subsequent
        // launches use FORCE_ONBOARDING_DONE to put it back to true so
        // every later shot lands in the granted-content view.
        app.launchEnvironment["DICTATOR_RESET_ONBOARDING"] = "1"
        app.launch()
        sleep(2)
        attach(name: "01-welcome", from: app)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "DICTATOR_RESET_ONBOARDING")
        app.launchEnvironment["DICTATOR_FORCE_ONBOARDING_DONE"] = "1"

        // 2. Idle — landing screen with mic / assist buttons.
        app.launch()
        sleep(2)
        attach(name: "02-idle", from: app)

        // 3. History — toolbar item on the trailing edge.
        let historyButton = app.buttons["History"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 4))
        historyButton.tap()
        sleep(1)
        attach(name: "04-history", from: app)

        // Back to root.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)

        // 4. Settings — toolbar item on the leading edge.
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        settingsButton.tap()
        sleep(1)
        attach(name: "06-settings", from: app)

        // 5. Mid-dictation — fake the recording status via the
        // `RecordingViewModel.init` hook. Need a relaunch for the env
        // var to take effect.
        app.terminate()
        app.launchEnvironment["DICTATOR_SCREENSHOT_STATE"] = "recording"
        app.launch()
        sleep(2)
        attach(name: "03-dictating", from: app)

        // 6. Keyboard showcase — swap the env var to render the
        // standalone keyboard mockup in `ContentView`. The real
        // keyboard is an app extension that can't be summoned
        // automatically in the simulator, so we use a pixel-faithful
        // mockup instead.
        app.terminate()
        app.launchEnvironment["DICTATOR_SCREENSHOT_STATE"] = "keyboard"
        app.launch()
        sleep(2)
        attach(name: "05-keyboard", from: app)
    }

    private func attach(name: String, from app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
