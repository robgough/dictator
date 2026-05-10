import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

enum DeliveryResult: Equatable, Sendable {
    case pasted
    case copiedOnly(reason: String)
}

@MainActor
final class TextInjector {
    /// Copies text to the pasteboard and synthesises ⌘V into the frontmost app.
    /// Returns whether the synthetic paste was actually attempted (it requires
    /// Accessibility permission). When permission is missing the previous
    /// clipboard is NOT restored, so the user can paste manually with ⌘V.
    @discardableResult
    func deliver(text: String) -> DeliveryResult {
        let pasteboard = NSPasteboard.general

        // Capture previous clipboard so we can restore it after a successful paste.
        let previous = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, String)? in
            for type in item.types {
                if let value = item.string(forType: type) { return (type, value) }
            }
            return nil
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard Self.hasAccessibilityPermission() else {
            // Trigger the one-shot system prompt so the user knows what to grant.
            Self.requestAccessibilityPrompt()
            return .copiedOnly(reason: "Accessibility permission required to paste. Text is on your clipboard — press ⌘V to paste.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            Self.synthesizeCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !previous.isEmpty else { return }
                pasteboard.clearContents()
                for (type, value) in previous {
                    pasteboard.setString(value, forType: type)
                }
            }
        }
        return .pasted
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private static func requestAccessibilityPrompt() {
        // `kAXTrustedCheckOptionPrompt` is a CFString global that Swift 6 treats as
        // non-Sendable. Its underlying value is documented as "AXTrustedCheckOptionPrompt".
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // ANSI 'V'

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
