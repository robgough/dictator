import AppKit

/// Watches `.flagsChanged` events globally and locally and reports press / release
/// for a single chosen modifier key (e.g. right option). Distinguishes left vs right
/// via `event.keyCode`, then confirms press/release by checking whether the matching
/// modifier flag is still asserted in `event.modifierFlags`.
///
/// Also watches `.keyDown`: if a real character key is pressed while the trigger
/// modifier is held, the modifier was being used as a *chord* (e.g. ⌥3 → "#" on a
/// British layout), not as a push-to-talk trigger. In that case it fires
/// `onChordCancel` and swallows the release, so an accidental trigger undoes itself
/// quietly. (Modifier keys emit `.flagsChanged`, not `.keyDown`, so a `.keyDown`
/// while held is always a genuine chord, never the trigger key itself.)
///
/// All four monitors fire on the main thread, so events are handled *synchronously*
/// via `MainActor.assumeIsolated` — NOT hopped through `Task`. Ordering is the whole
/// game here: the press (`flagsChanged`) must be processed before the chord key
/// (`keyDown`) so `pressed` is already set. Separate `Task`s run in an unspecified
/// order, which let the chord key beat the press and silently miss the cancel.
@MainActor
final class ModifierKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyDownGlobalMonitor: Any?
    private var keyDownLocalMonitor: Any?

    private var watchedKeyCode: UInt16?
    private var watchedFlag: NSEvent.ModifierFlags?
    private var pressed = false

    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onChordCancel: (() -> Void)?

    func start(keyCode: UInt16, modifierFlag: NSEvent.ModifierFlags,
               onPress: @escaping () -> Void, onRelease: @escaping () -> Void,
               onChordCancel: @escaping () -> Void = {}) {
        stop()
        watchedKeyCode = keyCode
        watchedFlag = modifierFlag
        self.onPress = onPress
        self.onRelease = onRelease
        self.onChordCancel = onChordCancel

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let key = event.keyCode
            let flagsRaw = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleParsed(keyCode: key, flagsRaw: flagsRaw) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let key = event.keyCode
            let flagsRaw = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleParsed(keyCode: key, flagsRaw: flagsRaw) }
            return event
        }
        keyDownGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flagsRaw = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleChordKey(flagsRaw: flagsRaw) }
        }
        keyDownLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flagsRaw = event.modifierFlags.rawValue
            MainActor.assumeIsolated { self?.handleChordKey(flagsRaw: flagsRaw) }
            return event
        }
    }

    func stop() {
        for monitor in [globalMonitor, localMonitor, keyDownGlobalMonitor, keyDownLocalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil
        localMonitor = nil
        keyDownGlobalMonitor = nil
        keyDownLocalMonitor = nil
        watchedKeyCode = nil
        watchedFlag = nil
        if pressed {
            pressed = false
            onRelease?()
        }
        onPress = nil
        onRelease = nil
        onChordCancel = nil
    }

    private func handleParsed(keyCode: UInt16, flagsRaw: UInt) {
        guard let watchedKeyCode, let watchedFlag else { return }
        guard keyCode == watchedKeyCode else { return }

        let active = NSEvent.ModifierFlags(rawValue: flagsRaw)
            .intersection(.deviceIndependentFlagsMask)
            .contains(watchedFlag)

        if active && !pressed {
            pressed = true
            onPress?()
        } else if !active && pressed {
            pressed = false
            onRelease?()
        }
    }

    /// A key was pressed while the trigger modifier is held → chord (⌥3, ⌥<anything>),
    /// not a push-to-talk hold. Cancel and swallow the release: clearing `pressed`
    /// makes the modifier's release a no-op in `handleParsed`. The `held` check uses
    /// the keystroke's own modifier flags, so it only fires on a genuine ⌥<key>.
    private func handleChordKey(flagsRaw: UInt) {
        guard let watchedFlag, pressed else { return }
        let held = NSEvent.ModifierFlags(rawValue: flagsRaw)
            .intersection(.deviceIndependentFlagsMask)
            .contains(watchedFlag)
        guard held else { return }
        pressed = false
        onChordCancel?()
    }
}
