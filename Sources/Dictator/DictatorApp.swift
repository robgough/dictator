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
            MenuBarContent(updater: updaterController.updater)
                .environment(appState)
        } label: {
            Image(systemName: appState.pipeline.state.iconName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .frame(width: 560, height: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: HUDController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = AppState.shared
        hud = HUDController(state: state)
        state.bootstrap()
    }
}
