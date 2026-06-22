import Foundation
import Observation

/// The observable backing the Scratchpad editor. Owns the live note text, a
/// debounced autosave, and a focus pulse the view watches to re-grab keyboard
/// focus each time the panel re-opens.
///
/// Saves are deliberately layered: a debounced write while typing (so a burst
/// of keystrokes collapses to one disk write), plus an immediate flush on
/// panel/tab close, on losing focus, on backgrounding, and at app termination
/// — the belt-and-braces against losing the last edit if the user quits
/// mid-sentence.
///
/// Cross-platform: lives in `DictatorCore` so both the macOS slide-in panel and
/// the iOS Scratchpad tab share one autosave/reload implementation. The note's
/// on-disk location is resolved by `bootstrap(customDirectory:)`, mirroring
/// `VocabularyStore` — macOS passes its `SyncedStorage` directory, iOS passes
/// the resolved `SharedFolderBookmark` folder (or nil for the sandbox default).
@MainActor
@Observable
final class ScratchpadModel {
    /// Shared instance used by the iOS Scratchpad tab and the recording view
    /// model's scratchpad-dictation path. macOS creates its own instance inside
    /// `ScratchpadController`, so this singleton is only realised on iOS (lazy
    /// `static let` — never constructed on macOS).
    static let shared = ScratchpadModel()

    /// The live note text. Edits made *through the editor* schedule a save (see
    /// the view's binding); programmatic assignment via `reload()` does not, so
    /// opening the editor never re-writes what it just read.
    var text: String = ""

    /// Bumped every time the editor is shown. `onAppear` only fires once for a
    /// reused host view, so the view also watches this to re-assert
    /// `@FocusState` on subsequent opens.
    var focusPulse: Int = 0

    /// Live caret / selection in the iOS editor, in UTF-16 offsets. Bound from
    /// the UIKit-backed editor and read by `RecordingViewModel` so a dictated
    /// chunk lands at the cursor (or replaces a highlighted range) and an
    /// assist instruction transforms just the selection. Transient — not
    /// persisted, unused on macOS (which has no selection-aware merge).
    var selection: NSRange?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Whether `reload()` has run successfully at least once for the current
    /// `fileURL`. Saves are gated on this: the model is created with empty
    /// `text`, and a termination/background flush fires whether or not the
    /// editor was ever opened — an ungated save would overwrite the note on
    /// disk with that never-loaded empty string.
    @ObservationIgnored private var hasLoaded = false

    /// What's on disk as far as this session knows — set on reload and after
    /// each save, so `saveNow()` can skip the write when nothing changed.
    @ObservationIgnored private var persistedText = ""

    /// The file the store currently reads/writes. nil before `bootstrap()`.
    @ObservationIgnored private(set) var fileURL: URL?

    /// Set just before a dictation / assist result is applied, so the iOS
    /// editor gently animates to reveal the new text instead of staying put.
    /// Other programmatic changes (undo, quick keys) leave it false so the view
    /// doesn't move. `@ObservationIgnored` — it's consumed by the editor on the
    /// same render the text change triggers, not observed on its own.
    @ObservationIgnored var revealCaretOnNextUpdate = false

    /// One-step undo target, snapshotted just before a programmatic change
    /// (dictation merge or assist transform) so a surprising edit — especially
    /// a whole-note reword — is one tap away from recovery. Observed so the
    /// undo button shows/hides. `undo()` swaps current ↔ previous.
    var previousText: String?

    /// True once `undo()` has run and the next tap would REDO (swap back).
    /// Reset to false when a fresh snapshot is taken. Drives the button's
    /// undo↔redo glyph. Observed.
    var didUndo = false

    /// True when there's a meaningful snapshot to swap to (either direction).
    var canUndo: Bool {
        guard let previousText else { return false }
        return previousText != text
    }

    /// macOS constructs its own instance; iOS uses `.shared`. Internal (not
    /// private) so the macOS controller can keep owning a dedicated model.
    init() {}

    /// True once a synced folder is wired up and a successful load has run.
    /// The iOS tab uses this to decide whether to show the "connect a shared
    /// folder to sync with your Mac" hint.
    var isReady: Bool { fileURL != nil }

    /// Resolve the note's file URL, then load it. Pass `nil` to use the default
    /// `~/Documents/Dictator/` location; pass a resolved synced/shared folder
    /// to point at it. Idempotent — a second call (e.g. the iOS user enabling a
    /// shared folder mid-session, or the macOS user relocating their synced
    /// folder) flushes any pending edit to the old location, then re-points and
    /// reloads from the new one.
    func bootstrap(customDirectory: URL?) {
        // Flush a pending debounced edit to the OLD location before we move.
        saveNow()

        let directory = customDirectory ?? SyncedStorage.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(ScratchpadStore.filename)

        // Re-points invalidate the loaded/persisted snapshot so the reload
        // below pulls cleanly from the new file rather than diffing against
        // the previous location's contents.
        hasLoaded = false
        persistedText = ""
        reload()
    }

    /// Reload from disk — picks up edits made on another device since the
    /// editor was last open. Cancels any pending save first so the fresh disk
    /// contents aren't immediately clobbered by a stale in-flight write.
    ///
    /// A failed read (file exists but is unreadable — evicted by iCloud while
    /// offline, say) keeps the previous in-memory state untouched: whatever was
    /// showing stays showing, and if nothing has loaded successfully yet, saves
    /// stay blocked so we can never overwrite a note we couldn't read. The next
    /// open retries.
    func reload() {
        guard let url = fileURL else { return }
        saveTask?.cancel()
        saveTask = nil
        guard let loaded = ScratchpadStore.load(from: url) else { return }
        text = loaded
        persistedText = loaded
        hasLoaded = true
    }

    /// Debounced autosave. Called on every keystroke; coalesces a typing burst
    /// into a single write ~0.6 s after the user pauses. Each call cancels the
    /// previous pending write, so only the latest snapshot ever lands.
    func scheduleSave() {
        guard hasLoaded, let url = fileURL else { return }
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            ScratchpadStore.save(snapshot, to: url)
            self?.persistedText = snapshot
            self?.saveTask = nil
        }
    }

    /// Flush immediately — on close, resign-focus, backgrounding, and
    /// termination, where waiting out the debounce could drop the last edit.
    /// No-ops if nothing was loaded this session or the text hasn't changed
    /// since the last write, so idle hide/quit paths never touch the file.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasLoaded, let url = fileURL, text != persistedText else { return }
        ScratchpadStore.save(text, to: url)
        persistedText = text
    }

    /// Ensure the note has been read from disk before a programmatic write
    /// (dictation / assist) so we never merge onto a stale empty buffer.
    /// bootstrap reloads at launch, so this is belt-and-braces.
    func ensureLoaded() {
        if !hasLoaded { reload() }
    }

    /// Capture the current text as the undo target. Called right before a
    /// dictation merge or assist transform applies its result. Resets the
    /// undo/redo direction so the button reads "undo".
    func snapshotForUndo() {
        previousText = text
        didUndo = false
    }

    /// Swap current ↔ previous. First call undoes; with the swap left in place
    /// the next call redoes — `didUndo` flips so the button shows the right
    /// glyph. Drops the selection (the prior string's offsets don't fit) and
    /// schedules a save.
    func undo() {
        guard let previous = previousText, previous != text else { return }
        let current = text
        text = previous
        previousText = current
        selection = nil
        didUndo.toggle()
        scheduleSave()
    }

}
