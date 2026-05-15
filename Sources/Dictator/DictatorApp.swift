import SwiftUI
import AppKit
import Sparkle

@main
struct DictatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    // Owns Sparkle's lifecycle for the whole app. `startingUpdater: true` lets
    // Sparkle do its scheduled background check; menu-driven manual checks go
    // through `updaterController.updater` too. SUFeedURL + SUPublicEDKey in
    // Info.plist are what Sparkle reads to find the feed and verify signatures.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            Image(systemName: appState.pipeline.state.iconName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(appState)
                .frame(width: 560, height: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: HUDController?
    // Held by the delegate so the strong reference outlives every
    // services-menu invocation. `NSApp.servicesProvider` is `weak`.
    private let learnWordProvider = LearnWordProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        hud = HUDController(state: state)
        state.bootstrap()

        // Hook up the Services menu provider. The matching NSServices
        // declaration in Info.plist is what makes "Learn Word in Dictator…"
        // appear in other apps' right-click \u{2192} Services submenu; this
        // is the object that handles the call when it fires. The
        // `NSUpdateDynamicServices()` nudge prompts pbs to re-scan the
        // bundle so a freshly-installed build's services show up without
        // requiring a logout.
        NSApp.servicesProvider = learnWordProvider
        NSUpdateDynamicServices()
    }
}
