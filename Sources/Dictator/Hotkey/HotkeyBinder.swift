import Foundation
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.d, modifiers: [.option, .command]))
    static let toggleAssistant = Self("toggleAssistant", default: .init(.a, modifiers: [.option, .command]))
}

/// One binder = one hotkey "channel" (e.g. dictation, or assistant). Each instance owns
/// its own ModifierKeyMonitor and a single KeyboardShortcuts.Name so two binders can
/// listen simultaneously without stepping on each other's monitors.
@MainActor
final class HotkeyBinder {
    /// How long a press has to be held before it counts as a hold (push-to-talk)
    /// rather than a tap (toggle). Matches the iOS app's HoldButton threshold so
    /// the two platforms feel identical.
    private static let holdThreshold: TimeInterval = 0.35

    let shortcutName: KeyboardShortcuts.Name

    /// The "start listening" action — fires on the first press.
    private var onPress: (() -> Void)?
    /// The "stop / commit" action — fires on release of a hold, or on the
    /// release of the second tap when latched.
    private var onRelease: (() -> Void)?
    /// Live read of the tap-to-toggle setting, so a settings change takes
    /// effect without rebinding.
    private var tapToToggle: () -> Bool = { false }
    private var currentMode: TriggerMode = .keyboardShortcut

    // Tap-vs-hold state. The decision is made at *release* time (like iOS):
    // a quick release latches; a long hold (or toggle disabled) stops.
    private var pressStartedAt: Date?
    private var isLatched = false
    private var stopOnRelease = false

    private let modifierMonitor = ModifierKeyMonitor()

    init(shortcutName: KeyboardShortcuts.Name) {
        self.shortcutName = shortcutName
    }

    func bind(mode: TriggerMode,
              onPress: @escaping () -> Void,
              onRelease: @escaping () -> Void,
              tapToToggle: @escaping () -> Bool = { false }) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.tapToToggle = tapToToggle
        apply(mode: mode)
    }

    /// Wrapped press handler. First press starts; a press while latched arms
    /// the stop for this press's release (so the second *tap* stops).
    private func handlePress() {
        guard let onPress else { return }
        if isLatched {
            stopOnRelease = true
            return
        }
        pressStartedAt = Date()
        onPress()
    }

    /// Wrapped release handler. Stops on a long hold or when toggle is off;
    /// latches (keeps listening) on a quick tap; or commits the pending stop
    /// when the user tapped a second time while latched.
    private func handleRelease() {
        guard let onRelease else { return }
        if stopOnRelease {
            stopOnRelease = false
            isLatched = false
            onRelease()
            return
        }
        let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        pressStartedAt = nil
        if tapToToggle(), elapsed < Self.holdThreshold {
            // Quick tap → latch on; keep listening until the next tap.
            isLatched = true
            return
        }
        isLatched = false
        onRelease()
    }

    func setMode(_ mode: TriggerMode) {
        guard onPress != nil, onRelease != nil else {
            currentMode = mode
            return
        }
        apply(mode: mode)
    }

    /// Restore the default keyboard combination for this binder's shortcut.
    func resetKeyboardShortcutToDefault() {
        KeyboardShortcuts.reset(shortcutName)
    }

    private func apply(mode: TriggerMode) {
        // Tear everything down before re-attaching the new mode.
        KeyboardShortcuts.removeHandler(for: shortcutName)
        modifierMonitor.stop()
        currentMode = mode
        // A rebind drops any in-flight tap/latch state — the physical key
        // events that would clear it may no longer be observed.
        pressStartedAt = nil
        isLatched = false
        stopOnRelease = false

        // The monitors always get the wrapped handlers; the tap-vs-hold
        // discrimination lives entirely in handlePress/handleRelease.
        switch mode {
        case .keyboardShortcut:
            guard onPress != nil, onRelease != nil else { return }
            KeyboardShortcuts.onKeyDown(for: shortcutName) { [weak self] in self?.handlePress() }
            KeyboardShortcuts.onKeyUp(for: shortcutName) { [weak self] in self?.handleRelease() }

        default:
            guard
                let keyCode = mode.keyCode,
                let flag = mode.modifierFlag,
                onPress != nil, onRelease != nil
            else { return }
            modifierMonitor.start(
                keyCode: keyCode,
                modifierFlag: flag,
                onPress: { [weak self] in self?.handlePress() },
                onRelease: { [weak self] in self?.handleRelease() }
            )
        }
    }
}
