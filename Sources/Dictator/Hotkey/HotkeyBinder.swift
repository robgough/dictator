import Foundation
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.d, modifiers: [.option, .command]))
}

@MainActor
final class HotkeyBinder {
    static let shared = HotkeyBinder()
    private init() {}

    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var currentMode: TriggerMode = .keyboardShortcut

    private let modifierMonitor = ModifierKeyMonitor()

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

    /// Restore the default keyboard combination shortcut (⌥⌘D).
    func resetKeyboardShortcutToDefault() {
        KeyboardShortcuts.reset(.toggleDictation)
    }

    private func apply(mode: TriggerMode) {
        // Tear everything down before re-attaching the new mode.
        KeyboardShortcuts.removeHandler(for: .toggleDictation)
        modifierMonitor.stop()
        currentMode = mode

        switch mode {
        case .keyboardShortcut:
            if let onPress { KeyboardShortcuts.onKeyDown(for: .toggleDictation, action: onPress) }
            if let onRelease { KeyboardShortcuts.onKeyUp(for: .toggleDictation, action: onRelease) }

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
