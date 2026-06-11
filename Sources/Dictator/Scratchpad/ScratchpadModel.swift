import Foundation
import Observation

/// The observable backing the Scratchpad editor. Owns the live note text, a
/// debounced autosave, and a focus pulse the view watches to re-grab keyboard
/// focus each time the panel re-opens.
///
/// Saves are deliberately layered: a debounced write while typing (so a burst
/// of keystrokes collapses to one disk write), plus an immediate flush on
/// panel close, on the panel losing key focus, and at app termination — the
/// belt-and-braces against losing the last edit if the user quits mid-sentence.
@MainActor
@Observable
final class ScratchpadModel {
    /// The live note text. Edits made *through the editor* schedule a save (see
    /// `ScratchpadView`'s binding); programmatic assignment via `reload()` does
    /// not, so opening the panel never re-writes what it just read.
    var text: String = ""

    /// Bumped by the controller every time the panel is shown. `onAppear` only
    /// fires once for a reused `NSHostingView`, so the view also watches this to
    /// re-assert `@FocusState` on subsequent opens.
    var focusPulse: Int = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Whether `reload()` has run at least once this session. Saves are gated
    /// on this: the model is created at app launch with empty `text`, and the
    /// termination flush fires whether or not the panel was ever opened — an
    /// ungated save would overwrite the note on disk with that never-loaded
    /// empty string every time the app quit without the Scratchpad being used.
    @ObservationIgnored private var hasLoaded = false

    /// What's on disk as far as this session knows — set on reload and after
    /// each save, so `saveNow()` can skip the write when nothing changed.
    @ObservationIgnored private var persistedText = ""

    /// Reload from disk — picks up edits made on another device since the panel
    /// was last open. Cancels any pending save first so the fresh disk contents
    /// aren't immediately clobbered by a stale in-flight write.
    ///
    /// A failed read (file exists but is unreadable — evicted by iCloud while
    /// offline, say) keeps the previous in-memory state untouched: whatever was
    /// showing stays showing, and if nothing has loaded successfully yet, saves
    /// stay blocked so we can never overwrite a note we couldn't read. The next
    /// panel open retries.
    func reload() {
        saveTask?.cancel()
        saveTask = nil
        guard let loaded = ScratchpadStore.load() else { return }
        text = loaded
        persistedText = loaded
        hasLoaded = true
    }

    /// Debounced autosave. Called on every keystroke; coalesces a typing burst
    /// into a single write ~0.6 s after the user pauses. Each call cancels the
    /// previous pending write, so only the latest snapshot ever lands.
    func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            ScratchpadStore.save(snapshot)
            self?.persistedText = snapshot
            self?.saveTask = nil
        }
    }

    /// Flush immediately — on close, resign-key, and termination, where waiting
    /// out the debounce could drop the last edit. No-ops if nothing was loaded
    /// this session or the text hasn't changed since the last write, so idle
    /// hide/quit paths never touch the file.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasLoaded, text != persistedText else { return }
        ScratchpadStore.save(text)
        persistedText = text
    }
}
