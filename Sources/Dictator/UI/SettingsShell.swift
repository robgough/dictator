import SwiftUI
import AppKit
import Sparkle

/// View-state shared between the Settings window's AppKit chrome (toolbar
/// items) and its SwiftUI content (sidebar + detail panes). The toolbar is
/// where per-pane controls live — the Models tabs, the Dictation tabs, the
/// add-mode button, Dictionary search/sort/add, History clear — so the state
/// they drive has to sit outside any single pane.
@MainActor @Observable
final class SettingsShellModel {
    /// Selected sidebar section.
    var section: SettingsSection = .general

    /// Dictation pane: which sub-pane the toolbar's segmented control shows.
    var dictationTab: DictationSubPane = .modes

    /// Models pane: which sub-pane the toolbar's segmented control shows.
    var modelsTab: ModelsSubPane = .transcription

    /// Dictation → Modes: the mode whose editor sheet is open, if any. The
    /// pane presents `ModeEditorSheet` off this; nil closes it.
    var modeEditorID: UUID?
    /// Dictation → Modes: presents the "+" gallery sheet (triggered from the
    /// toolbar, presented by the pane).
    var showAddModeSheet = false

    /// Dictionary pane: live search text, mirrored from the toolbar's
    /// native search field.
    var dictionarySearch = ""
    /// Dictionary pane: sort order, driven by the toolbar's sort menu.
    var dictionarySort: VocabularySortOrder = .alphabetical
    /// Dictionary pane: set by the toolbar's Add button so the pane can
    /// focus the freshly inserted row's pattern field. The pane consumes
    /// (nils) it after applying focus.
    var dictionaryFocusEntryID: VocabularyEntry.ID?

    /// History pane: presents the destructive clear confirmation (triggered
    /// from the toolbar, presented by the pane).
    var confirmHistoryClear = false
}

/// Sparkle lives in a global holder (not on the `App` struct) so the Settings
/// window controller can reach the updater for the About pane. First touch
/// starts the background update schedule; `AppDelegate` touches it at launch,
/// preserving the old app-init timing.
@MainActor
enum SparkleUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// The Settings window, owned outright in AppKit rather than via SwiftUI's
/// `Settings` scene. History: the scene version hand-faked System Settings
/// chrome (transparent titlebar + content drawn into the strip), but
/// `NSTitlebarContainerView` intercepts clicks across the strip, so any
/// control drawn there — header tabs, back button, search — went dead. A real
/// `NSSplitViewController` + unified `NSToolbar` gives working controls,
/// native sidebar material, a tracking separator, and centred traffic lights.
/// (`NavigationSplitView` remains off the table: rdar://122947424.)
///
/// The sidebar and detail panes stay SwiftUI, hosted in
/// `NSHostingController`s; stateful toolbar items are SwiftUI fragments in
/// `NSHostingView`s, icon buttons are plain bordered `NSToolbarItem`s.
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    let model = SettingsShellModel()
    private var window: NSWindow?

    /// Opens (or re-fronts) the Settings window. Activation-policy games are
    /// the caller's business — the `dictator://settings` handler flips to
    /// `.regular` first, the menu-bar button doesn't — matching the old
    /// Settings-scene behaviour.
    func show() {
        if window == nil {
            window = makeWindow()
            observeStructure()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let state = AppState.shared
        let sidebarVC = NSHostingController(
            rootView: SettingsSidebar(shell: model).environment(state)
        )
        let detailVC = NSHostingController(
            rootView: SettingsDetailRoot(shell: model, updater: SparkleUpdater.controller.updater)
                .environment(state)
        )
        // No SwiftUI-derived size constraints: by default NSHostingController
        // feeds its content's min/ideal sizes into Auto Layout, and panes
        // whose ideal height is their full scroll content (Modes especially)
        // ratchet the window to full height and pin its minimum there. The
        // panes fill whatever the split view gives them; the window's
        // `contentMinSize` below is the only size floor.
        sidebarVC.sizingOptions = []
        detailVC.sizingOptions = []

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        // Fixed-width sidebar, like System Settings — no drag handle to fiddle.
        sidebarItem.minimumThickness = 215
        sidebarItem.maximumThickness = 215
        sidebarItem.canCollapse = false
        // Full-height sidebar: material runs up behind the titlebar, and the
        // toolbar separator only spans the detail column.
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.titlebarSeparatorStyle = .automatic
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            // `.fullSizeContentView` is what lets `allowsFullHeightLayout`
            // actually engage: without it the sidebar stops below the
            // titlebar, AppKit draws a separator line across the full window
            // width under the header, and the sidebar tracking separator's
            // divider tick floats unanchored in the toolbar. With it, the
            // sidebar material runs to the window top and the titlebar
            // separator spans only the detail column (System Settings-style).
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.setContentSize(NSSize(width: 920, height: 680))
        window.contentMinSize = NSSize(width: 720, height: 540)
        // The page title is the real window title — with a unified toolbar
        // and a sidebar tracking separator AppKit renders it after the
        // separator, Finder-style, and crucially with no liquid-glass capsule
        // around it. (A custom text toolbar item gets wrapped in glass on
        // macOS 26 and looks like a button that does nothing.)
        // `refreshWindowTitle()` keeps it current; the AppDelegate
        // close-observer that reverts activation policy also keys on it.
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "DictatorSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.centeredItemIdentifiers = [.modelsTabs, .dictationTabs]
        window.toolbar = toolbar

        if !window.setFrameUsingName("DictatorSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("DictatorSettingsWindow")

        refreshWindowTitle()
        return window
    }

    // MARK: - Toolbar structure

    /// The item list for the current shell state. Left of the tracking
    /// separator is the (empty) sidebar section; after it, per-pane controls.
    /// Only real controls belong here — text (the page title, counts, badges)
    /// gets wrapped in a liquid-glass capsule on macOS 26 and reads as a
    /// broken button, so titles are the window title and informational text
    /// lives in pane content.
    private var currentIdentifiers: [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [.sidebarTrackingSeparator]
        switch model.section {
        case .models:
            // Centred via `centeredItemIdentifiers`; the flexible spaces keep
            // it away from the title when the window is narrow.
            ids += [.flexibleSpace, .modelsTabs, .flexibleSpace]
        case .dictation:
            ids += [.flexibleSpace, .dictationTabs, .flexibleSpace]
            switch model.dictationTab {
            case .modes:      ids.append(.addMode)
            case .microphone: break
            case .history:    ids.append(.historyClear)
            }
        case .dictionary:
            ids += [.flexibleSpace, .dictionarySearch, .dictionarySort, .dictionaryAdd]
        default:
            break
        }
        return ids
    }

    /// Rebuilds the toolbar when its *structure* changes (section switch,
    /// Dictation sub-tab switch — the "+" and Clear buttons belong to one tab
    /// each). Item content that merely changes value — counts, disabled
    /// states — updates itself: those items are SwiftUI fragments observing
    /// the same model.
    private func observeStructure() {
        withObservationTracking {
            _ = model.section
            _ = model.dictationTab
            refreshWindowTitle()
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadToolbar()
                self.observeStructure()
            }
        }
    }

    private func reloadToolbar() {
        guard let toolbar = window?.toolbar else { return }
        let target = currentIdentifiers
        // The observation also fires for title-only changes (mode renames);
        // don't tear the items down unless the structure actually differs.
        guard toolbar.items.map(\.itemIdentifier) != target else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in target.enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }

    /// The window title is always the section title. (The mode editor is a
    /// sheet with its own title now; it used to be a drill-in that swapped
    /// this out for the mode's name.)
    private func refreshWindowTitle() {
        window?.title = model.section.title
    }

    // MARK: - Toolbar item actions

    @objc private func addMode() {
        model.showAddModeSheet = true
    }

    @objc private func dictionarySearchChanged(_ sender: NSSearchField) {
        model.dictionarySearch = sender.stringValue
    }

    /// Mirrors the old in-pane Add button: new empty rule at the top, sort
    /// flipped to "as entered" and search cleared so the row is visible, then
    /// a focus request the pane applies.
    @objc private func addDictionaryEntry() {
        let new = VocabularyEntry(pattern: "", replacement: "")
        VocabularyStore.shared.entries.insert(new, at: 0)
        AppState.shared.save()
        model.dictionarySort = .asEntered
        model.dictionarySearch = ""
        if let searchItem = window?.toolbar?.items.first(where: { $0.itemIdentifier == .dictionarySearch }) as? NSSearchToolbarItem {
            searchItem.searchField.stringValue = ""
        }
        model.dictionaryFocusEntryID = new.id
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        currentIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .space,
         .dictationTabs, .modelsTabs, .addMode,
         .dictionarySearch, .dictionarySort, .dictionaryAdd, .historyClear]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .dictationTabs:
            return hostingItem(itemIdentifier, label: "Section",
                               DictationToolbarTabs(shell: model))
        case .modelsTabs:
            return hostingItem(itemIdentifier, label: "Section",
                               ModelsToolbarTabs(shell: model))
        case .addMode:
            return borderedItem(itemIdentifier, symbol: "plus",
                                label: "Add Mode", action: #selector(addMode))
        case .dictionarySearch:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search"
            item.preferredWidthForSearchField = 190
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(dictionarySearchChanged(_:))
            item.searchField.stringValue = model.dictionarySearch
            return item
        case .dictionarySort:
            return hostingItem(itemIdentifier, label: "Sort",
                               DictionarySortMenu(shell: model))
        case .dictionaryAdd:
            return borderedItem(itemIdentifier, symbol: "plus",
                                label: "Add Entry", action: #selector(addDictionaryEntry))
        case .historyClear:
            return hostingItem(itemIdentifier, label: "Clear",
                               HistoryClearButton(shell: model))
        default:
            return nil
        }
    }

    private func hostingItem<V: View>(_ id: NSToolbarItem.Identifier, label: String, _ view: V) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.view = NSHostingView(rootView: view.environment(AppState.shared))
        return item
    }

    private func borderedItem(_ id: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let dictationTabs = Self("settings.dictationTabs")
    static let modelsTabs = Self("settings.modelsTabs")
    static let addMode = Self("settings.addMode")
    static let dictionarySearch = Self("settings.dictionarySearch")
    static let dictionarySort = Self("settings.dictionarySort")
    static let dictionaryAdd = Self("settings.dictionaryAdd")
    static let historyClear = Self("settings.historyClear")
}

// MARK: - Toolbar SwiftUI fragments
//
// Only interactive controls — text in a toolbar item gets a liquid-glass
// capsule on macOS 26 and reads as a broken button. Titles are the window
// title; counts and badges live in pane content.

private struct DictationToolbarTabs: View {
    @Bindable var shell: SettingsShellModel

    var body: some View {
        Picker("Dictation section", selection: $shell.dictationTab) {
            ForEach(DictationSubPane.allCases) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct ModelsToolbarTabs: View {
    @Bindable var shell: SettingsShellModel

    var body: some View {
        Picker("Models section", selection: $shell.modelsTab) {
            ForEach(ModelsSubPane.allCases) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct DictionarySortMenu: View {
    @Bindable var shell: SettingsShellModel

    var body: some View {
        Picker("Sort", selection: $shell.dictionarySort) {
            ForEach(VocabularySortOrder.allCases) { order in
                Text(order.label).tag(order)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }
}

/// Just the button — the record count lives in the pane's footnote, since
/// bare text in a toolbar item would get its own glass capsule.
private struct HistoryClearButton: View {
    @Bindable var shell: SettingsShellModel
    @State private var history = DictationHistory.shared

    var body: some View {
        Button(role: .destructive) {
            shell.confirmHistoryClear = true
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .disabled(history.records.isEmpty)
    }
}
