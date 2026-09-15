import AppKit
import SwiftUI

/// View state shared between the Chat window's AppKit chrome and its SwiftUI
/// content — the same split `SettingsShellModel` makes, for the same reason:
/// the toolbar lives outside any one pane but drives what the panes show.
@MainActor @Observable
final class ChatShellModel {
    /// Thread on screen. nil means the empty state.
    var selectedThreadID: UUID?
    /// Composer text, held here so the toolbar's "New chat" can clear it.
    var draft: String = ""
    /// Set when the user picks a thread that was talking to a different model.
    var modelSwitchNotice: String?

    let engine: ChatEngine
    /// Voice input for the composer. Owned here, not by the view, so closing
    /// the window can stop the microphone — a SwiftUI `onDisappear` is not
    /// guaranteed to run for a hosting controller the window keeps alive, and
    /// a mic left recording behind a closed window is the one failure this app
    /// must never have.
    let dictation = ChatDictation()

    init(engine: ChatEngine) {
        self.engine = engine
    }
}

/// The Chat window.
///
/// AppKit-owned for the same reasons Settings is (see `SettingsWindowController`):
/// a real `NSSplitViewController` gives native sidebar material, a working
/// tracking separator and a unified toolbar, none of which the SwiftUI
/// equivalents produce correctly here. `NavigationSplitView` is off the table
/// outright — rdar://122947424, recorded in the
/// `navigationsplitview_safearea_bug` note.
@MainActor
final class ChatWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    static let shared = ChatWindowController()

    let model = ChatShellModel(engine: ChatEngine(settings: { AppState.shared.settings }))
    private var window: NSWindow?

    /// Opens the window, creating it on first use.
    ///
    /// Dictator is an `LSUIElement` accessory, which can't reliably show a
    /// regular window until it flips to `.regular` — the same dance
    /// `dictator://settings` does. The AppDelegate's close-observer flips back
    /// to `.accessory` when a titled window closes, so the dock icon doesn't
    /// outlive the window.
    func show() {
        if window == nil {
            window = makeWindow()
        }
        if model.selectedThreadID == nil {
            selectMostRecentOrNew()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Starts a fresh thread and focuses the composer.
    func newThread() {
        let thread = ChatThread(modelID: AppState.shared.settings.llmModelID)
        ChatStore.shared.upsert(thread)
        ChatStore.shared.pruneEmpty(keeping: thread.id)
        select(threadID: thread.id)
        model.draft = ""
    }

    func select(threadID: UUID) {
        model.selectedThreadID = threadID
        model.engine.threadID = threadID
        model.modelSwitchNotice = noticeForModelMismatch(threadID: threadID)
    }

    /// Opening a thread that was talking to a different model is worth saying
    /// out loud: the reply style changes, and on a model without `chatCapable`
    /// the thread can't be continued at all.
    private func noticeForModelMismatch(threadID: UUID) -> String? {
        guard let thread = ChatStore.shared.thread(id: threadID),
              let threadModel = thread.modelID,
              !thread.isEmpty
        else { return nil }
        let current = AppState.shared.settings.llmModelID
        guard threadModel != current else { return nil }
        let was = ModelCatalog.llm(id: threadModel)?.displayName ?? threadModel
        let now = ModelCatalog.llm(id: current)?.displayName ?? current
        return "This chat was with \(was). New replies will come from \(now)."
    }

    private func selectMostRecentOrNew() {
        if let first = ChatStore.shared.threads.first {
            select(threadID: first.id)
        } else {
            newThread()
        }
    }

    // MARK: - Window

    private func makeWindow() -> NSWindow {
        let state = AppState.shared
        let sidebarVC = NSHostingController(
            rootView: ChatSidebar(shell: model).environment(state))
        let detailVC = NSHostingController(
            rootView: ChatDetailRoot(shell: model).environment(state))
        // Same reason as Settings: NSHostingController otherwise feeds its
        // content's ideal height into Auto Layout and ratchets the window.
        sidebarVC.sizingOptions = []
        detailVC.sizingOptions = []

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 230
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.titlebarSeparatorStyle = .automatic
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 900, height: 660))
        window.contentMinSize = NSSize(width: 640, height: 420)
        // A title is required, not cosmetic: the AppDelegate reverts the
        // activation policy on the close of any *titled* window, which is how
        // the dock icon goes away again.
        window.title = "Chat"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self

        let toolbar = NSToolbar(identifier: "DictatorChatToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        if !window.setFrameUsingName("DictatorChatWindow") {
            window.center()
        }
        window.setFrameAutosaveName("DictatorChatWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Don't leave a generation running — or the microphone open — against a
        // window nobody can see.
        model.engine.cancel()
        model.dictation.cancel()
        ChatStore.shared.pruneEmpty(keeping: nil)
        ChatStore.shared.flush()
    }

    // MARK: - Toolbar

    private static let newChatItem = NSToolbarItem.Identifier("chat.new")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, Self.newChatItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.newChatItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "New Chat"
        item.toolTip = "Start a new chat"
        item.image = NSImage(
            systemSymbolName: "square.and.pencil", accessibilityDescription: "New chat")
        item.isBordered = true
        item.target = self
        item.action = #selector(newChatFromToolbar)
        return item
    }

    @objc private func newChatFromToolbar() {
        newThread()
    }
}
