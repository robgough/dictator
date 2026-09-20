import AppKit
import SwiftUI

/// View state shared between the Journal window's AppKit chrome and its SwiftUI
/// content — the same split `ChatShellModel` and `SettingsShellModel` make, for
/// the same reason: the toolbar sits outside any one pane but drives what the
/// panes do.
@MainActor
@Observable
final class JournalShellModel {
    /// The new-entry box.
    var draft = ""
    /// Photos staged for that entry, copied in only when it's saved — so
    /// abandoning a draft leaves nothing behind in the journal folder.
    var pendingImages: [URL] = []
    /// Bumped when something should put the cursor in the writing box —
    /// dropping a photo on the page, for instance.
    var focusRequests = 0

    /// The entry being edited in place, if any.
    var editing: JournalArchive.Entry?
    var editDraft = ""
    /// The photos that entry keeps. Removing one here removes its line from
    /// the entry when the edit is saved; the file itself is left on disk.
    var editImages: [JournalMarkdown.ImageRef] = []
    var editNewImages: [URL] = []

    /// The entry the user has asked to delete, held while we confirm.
    var confirmingDelete: JournalArchive.Entry?

    /// The month the sidebar is showing. Not the same thing as the selected
    /// day: you can page back through months without choosing a day.
    var visibleMonth: Date = Date()

    func beginEditing(_ entry: JournalArchive.Entry) {
        editing = entry
        editDraft = JournalMarkdown.prose(in: entry.text)
        editImages = JournalMarkdown.images(in: entry.text)
        editNewImages = []
    }

    func cancelEditing() {
        editing = nil
        editDraft = ""
        editImages = []
        editNewImages = []
    }

    func focusComposer() { focusRequests += 1 }
}

/// The Journal window.
///
/// AppKit-owned for the same reasons Chat and Settings are: a real
/// `NSSplitViewController` gives native sidebar material, a working tracking
/// separator and a unified toolbar. `NavigationSplitView` is off the table —
/// rdar://122947424, recorded in the `navigationsplitview_safearea_bug` note.
@MainActor
final class JournalWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    static let shared = JournalWindowController()

    let model = JournalShellModel()
    private var window: NSWindow?
    /// Re-reads the day on screen while the window is in front. These are files
    /// other apps write too; see `JournalStore` for why this is a refresh
    /// rather than a watch.
    private var refreshTimer: Timer?

    func show() {
        if window == nil {
            window = makeWindow()
        }
        JournalStore.shared.beginObserving()
        JournalStore.shared.refresh()
        // Dictator is an `LSUIElement` accessory and can't reliably show a
        // regular window until it flips to `.regular`. The AppDelegate's
        // close-observer flips it back when a titled window closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open on the day a particular journal file covers.
    ///
    /// Used by the HUD after an entry lands: the moment you've just spoken a
    /// thought into a file is exactly when you might want to look at it, and
    /// what you want to see is the entry on its page — not a Markdown file in
    /// whatever app happens to own `.md`. The page has Open and Show in Finder
    /// on it for when the file itself is the point.
    ///
    /// The day is selected *before* `show()` so the refresh it kicks off keeps
    /// this choice rather than falling back to today — which matters for an
    /// entry written just after midnight, or into a custom template.
    func show(fileURL: URL) {
        if let key = JournalStore.shared.dayKey(for: fileURL) {
            JournalStore.shared.select(key: key)
        }
        show()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let state = AppState.shared
        let sidebarVC = NSHostingController(
            rootView: JournalSidebar(shell: model).environment(state))
        let detailVC = NSHostingController(
            rootView: JournalDayView(shell: model).environment(state))
        // Same reason as Chat and Settings: an NSHostingController otherwise
        // feeds its content's ideal height into Auto Layout and ratchets the
        // window taller every time the content grows.
        sidebarVC.sizingOptions = []
        detailVC.sizingOptions = []

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        // 20pt wider than Chat's: the calendar has seven columns and a
        // squeezed one stops reading as a month.
        sidebarItem.minimumThickness = 250
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.titlebarSeparatorStyle = .automatic
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 880, height: 640))
        window.contentMinSize = NSSize(width: 660, height: 440)
        // The title is load-bearing, not decoration: the AppDelegate reverts the
        // activation policy when a *titled* window closes, which is how the
        // dock icon goes away again.
        window.title = "Dictator Journal"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self

        let toolbar = NSToolbar(identifier: "DictatorJournalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        if !window.setFrameUsingName("DictatorJournalWindow") {
            window.center()
        }
        window.setFrameAutosaveName("DictatorJournalWindow")
        return window
    }

    // MARK: - Staying current

    func windowDidBecomeKey(_ notification: Notification) {
        // Coming back to the window is exactly the gesture that follows editing
        // the same file somewhere else.
        JournalStore.shared.refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in JournalStore.shared.refreshIfUnchanged() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        JournalStore.shared.endObserving()
        // A capture the window started is still the journal hotkey's capture
        // and will file itself correctly whatever happens to this window, so
        // there is nothing to cancel — unlike Chat, this window owns no
        // recorder of its own.
        model.cancelEditing()
    }

    // MARK: - Toolbar

    /// Nothing but the split divider.
    ///
    /// Recording and writing both started life up here and neither worked: a
    /// microphone in the titlebar put the controls for a recording at the
    /// opposite end of the window from the entry it was making, and there was
    /// nowhere sensible to show its state or its cancel button. Recording now
    /// lives at the foot of the sidebar with its own stop and discard, and the
    /// entry draws itself on the page as it arrives.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}
