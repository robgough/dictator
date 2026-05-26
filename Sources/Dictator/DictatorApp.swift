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
                .onOpenURL { url in handleURL(url) }
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
        .handlesExternalEvents(matching: ["settings"])

        WindowGroup(id: "meetings") {
            MeetingsRootView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
        .handlesExternalEvents(matching: ["meetings"])
    }

    /// Routes incoming `dictator://…` URLs. Three hosts handled today:
    /// `settings` opens the Settings window, `onboarding` re-shows the
    /// wizard, `meetings` opens the Meetings window. Anything else is
    /// logged and ignored.
    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "dictator" else { return }
        switch url.host?.lowercased() {
        case "settings":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "onboarding", "setup", "wizard":
            NSApp.activate(ignoringOtherApps: true)
            appState.showOnboarding()
        case "meetings":
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            appState.openMeetingsAction?()
        default:
            NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: HUDController?
    // Held by the delegate so the strong reference outlives every
    // services-menu invocation. `NSApp.servicesProvider` is `weak`.
    private let learnWordProvider = LearnWordProvider()

    /// Routes `dictator://…` URLs. Two hosts handled:
    /// `dictator://settings` opens the Settings window; `dictator://onboarding`
    /// (or `setup` / `wizard`) re-shows the first-run wizard. Useful both as
    /// a deep-link target for support docs and for automation.
    ///
    /// `.onOpenURL` on a MenuBarExtra scene doesn't fire for `LSUIElement`
    /// apps, so we handle URLs here in the AppDelegate.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "dictator" else { continue }
            switch url.host?.lowercased() {
            case "settings":
                Task { @MainActor in
                    // Accessory apps can't reliably show a regular window
                    // until they flip to .regular. We bounce here and the
                    // settings-window observer (below) flips back to
                    // .accessory once the user closes it, so the dock
                    // icon doesn't persist after Settings is dismissed.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    // SwiftUI 14+ emits a runtime fault if we open Settings
                    // via `showSettingsWindow:` from outside the SwiftUI
                    // hierarchy — it wants `SettingsLink`. The captured
                    // action stored on AppState (set when MenuBarContent's
                    // body first runs) is the blessed equivalent. The
                    // fallback is only used before any popover render.
                    if let open = AppState.shared.openSettingsAction {
                        open()
                    } else {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
            case "onboarding", "setup", "wizard":
                NSApp.activate(ignoringOtherApps: true)
                AppState.shared.showOnboarding()
            case "meetings":
                Task { @MainActor in
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    AppState.shared.openMeetingsAction?()
                }
            default:
                NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // When the user closes the Settings window (which we may have
        // opened via the dictator://settings URL — and which forces
        // .regular activation to be visible), revert to .accessory so the
        // dock icon doesn't persist. Filter by title because Settings is
        // the only window whose title matches the selected tab name on
        // macOS — the other windows we create (HUD, assistant result)
        // are NSPanel with empty titles.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            // Settings windows are titled by the active tab ("General",
            // "Models", etc.). HUD / result windows have no title.
            let title = win.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            // Defer the policy change a tick so the window-close animation
            // doesn't race with hiding the dock icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
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
