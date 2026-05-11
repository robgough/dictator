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
    let shortcutName: KeyboardShortcuts.Name

    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var currentMode: TriggerMode = .keyboardShortcut

    private let modifierMonitor = ModifierKeyMonitor()

    init(shortcutName: KeyboardShortcuts.Name) {
        self.shortcutName = shortcutName
    }

    func bind(mode: TriggerMode,
              onPress: @escaping () -> Void,
              onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        apply(mode: mode)
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

        switch mode {
        case .keyboardShortcut:
            if let onPress { KeyboardShortcuts.onKeyDown(for: shortcutName, action: onPress) }
            if let onRelease { KeyboardShortcuts.onKeyUp(for: shortcutName, action: onRelease) }

        default:
            guard
                let keyCode = mode.keyCode,
                let flag = mode.modifierFlag,
                let onPress, let onRelease
            else { return }
            modifierMonitor.start(keyCode: keyCode, modifierFlag: flag, onPress: onPress, onRelease: onRelease)
        }
    }
}
