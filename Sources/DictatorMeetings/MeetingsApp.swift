import SwiftUI
import AppKit
import Sparkle

/// Sparkle's lifecycle holder for the Meetings app. Dictator keeps its own copy
/// (SettingsShell.swift) — the two processes each run their own updater against
/// their own appcast feed (`SUFeedURL` in project.yml), so this is a copy rather
/// than a shared type in DictatorMac: sharing it would give one process's holder
/// to both, and there's no state worth sharing anyway.
@MainActor
enum SparkleUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Dictator Meetings — the standalone meeting recorder / note-taker.
///
/// Unlike Dictator (an `LSUIElement` accessory app driven from the menu bar),
/// this is a regular windowed app: it opens its window at launch and has a Dock
/// icon. This file is a skeleton; Agent F fills in the Settings window and
/// Agent G moves the meetings UI in behind `Window("Meetings")`.
@main
struct DictatorMeetingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single `Window`, NOT a `WindowGroup`: Meetings is one-per-app, so
        // reopening re-fronts the existing window instead of spawning a
        // duplicate, and there's no ⌘N "new window" command.
        Window("Meetings", id: "meetings") {
            PlaceholderRootView()
                // 1000 = sidebar max (320) + the detail's compressed width +
                // the Details inspector's 240pt minimum, with room for the
                // dividers. Kept from Dictator's Meetings scene so the real
                // layout drops in without re-tuning.
                .frame(minWidth: 1000, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 760)

        // A plain SwiftUI `Settings` scene, unlike Dictator's AppKit-owned
        // window: Meetings has a handful of tabs and no sidebar, so the scene's
        // limitations (dead controls in a faked titlebar strip) don't bite.
        Settings {
            PlaceholderSettingsView()
        }
    }
}

/// Stand-in for `MeetingsRootView`, which arrives with the meetings code.
private struct PlaceholderRootView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Dictator Meetings")
                .font(.title2.weight(.semibold))
            Text("Meetings move in here next.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stand-in for `MeetingsSettingsView`.
private struct PlaceholderSettingsView: View {
    var body: some View {
        Text("Settings move in here next.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(40)
            .frame(width: 520, height: 320)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard, same as Dictator's. Two copies with the same
        // bundle ID can run side by side when they live at different paths —
        // the installed ~/Applications build alongside a DerivedData ⌘R build,
        // say — because Launch Services only dedupes launches by path. Each
        // instance would record and write notes independently. Defer to
        // whoever's already running and bail before bootstrapping anything.
        if let existing = Self.alreadyRunningInstance() {
            NSLog("[DictatorMeetings] Another instance (pid \(existing.processIdentifier)) is already running; quitting this one.")
            NSApp.terminate(nil)
            return
        }

        // Start Sparkle's background update schedule (first touch creates the
        // controller with `startingUpdater: true`).
        _ = SparkleUpdater.controller
    }

    /// Quitting with the last window closed is right for a windowed app whose
    /// only surface is that window — until the menu-bar status item lands
    /// (Agent G), at which point this becomes conditional on
    /// `showMenuBarStatus`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// The already-running Dictator Meetings instance, if any, excluding this
    /// process. Matches on bundle identifier so it catches a copy launched from
    /// a different path — Launch Services only dedupes by path, so those
    /// otherwise run side by side.
    private static func alreadyRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myPID = NSRunningApplication.current.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
    }
}
