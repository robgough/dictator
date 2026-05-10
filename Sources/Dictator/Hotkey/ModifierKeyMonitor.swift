import AppKit

/// Watches `.flagsChanged` events globally and locally and reports press / release
/// for a single chosen modifier key (e.g. right option). Distinguishes left vs right
/// via `event.keyCode`, then confirms press/release by checking whether the matching
/// modifier flag is still asserted in `event.modifierFlags`.
@MainActor
final class ModifierKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var watchedKeyCode: UInt16?
    private var watchedFlag: NSEvent.ModifierFlags?
    private var pressed = false

    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?

    func start(keyCode: UInt16, modifierFlag: NSEvent.ModifierFlags,
               onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        stop()
        watchedKeyCode = keyCode
        watchedFlag = modifierFlag
        self.onPress = onPress
        self.onRelease = onRelease

        // Extract Sendable values synchronously — NSEvent itself is non-Sendable and
        // would be illegal to capture in a @Sendable Task body.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let key = event.keyCode
            let flagsRaw = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handleParsed(keyCode: key, flagsRaw: flagsRaw)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let key = event.keyCode
            let flagsRaw = event.modifierFlags.rawValue
            Task { @MainActor [weak self] in
                self?.handleParsed(keyCode: key, flagsRaw: flagsRaw)
            }
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        watchedKeyCode = nil
        watchedFlag = nil
        if pressed {
            pressed = false
            onRelease?()
        }
        onPress = nil
        onRelease = nil
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
}
