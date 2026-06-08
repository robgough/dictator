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

    /// Reload from disk — picks up edits made on another device since the panel
    /// was last open. Cancels any pending save first so the fresh disk contents
    /// aren't immediately clobbered by a stale in-flight write.
    func reload() {
        saveTask?.cancel()
        saveTask = nil
        text = ScratchpadStore.load()
    }

    /// Debounced autosave. Called on every keystroke; coalesces a typing burst
    /// into a single write ~0.6 s after the user pauses. Each call cancels the
    /// previous pending write, so only the latest snapshot ever lands.
    func scheduleSave() {
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            ScratchpadStore.save(snapshot)
            self?.saveTask = nil
        }
    }

    /// Flush immediately — on close, resign-key, and termination, where waiting
    /// out the debounce could drop the last edit.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        ScratchpadStore.save(text)
    }
}
