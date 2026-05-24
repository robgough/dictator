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
    ///
    /// When `selectAfterPaste` is true (assistant REPLACE), the focused
    /// element's selection range is captured before the paste and re-set
    /// afterwards to cover the just-inserted text — so the user can immediately
    /// reprompt or tweak what the assistant produced.
    @discardableResult
    func deliver(text: String, selectAfterPaste: Bool = false, pressReturnAfter: Bool = false) -> DeliveryResult {
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

        // Capture pre-paste selection up-front: the focused element and the
        // location of the existing selection/cursor. After the paste lands the
        // cursor sits at (location + pastedLength) and the selection is empty,
        // so we re-set it to (location, pastedLength) to cover the new text.
        let preSelection: PreSelection? = selectAfterPaste ? Self.capturePreSelection() : nil
        let pastedLength = text.utf16.count

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            Self.synthesizeCommandV()
            if let pre = preSelection {
                // Small delay so the host app has processed the ⌘V and updated
                // its text storage before we set the selection range.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    Self.setSelectedRange(pre.element, location: pre.location, length: pastedLength)
                }
            }
            if pressReturnAfter {
                // 150 ms after the paste fires gives the host app time to
                // process ⌘V and update its text storage / send-on-Return
                // state. Shorter than that and apps like Slack and Discord
                // occasionally swallow the Return (paste hasn't landed
                // yet, so Return is interpreted in a state where the
                // input field doesn't exist or is still empty).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    Self.synthesizeReturn()
                }
            }
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

    /// Whether the system-wide focused UI element is an editable text input.
    /// Used by the assistant pipeline to decide whether a `MODE: REPLACE` reply
    /// should actually paste (text input focused) or fall back to DRAFT-style
    /// clipboard-only delivery (nothing useful to paste into — e.g. a browser
    /// viewing a page with no input focused).
    static func focusedElementIsEditableText() -> Bool {
        guard hasAccessibilityPermission() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return false }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if let role, editableRoles.contains(role) { return true }

        // Some apps expose search fields / web inputs via a subrole rather than
        // a distinct role — fall through to the subrole check before giving up.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String {
            let editableSubroles: Set<String> = [
                kAXSearchFieldSubrole as String,
                kAXSecureTextFieldSubrole as String,
            ]
            if editableSubroles.contains(subrole) { return true }
        }
        return false
    }

    /// Pre-paste capture of the focused text element and its current selection
    /// location. The location stays valid across the paste because synthetic
    /// ⌘V replaces the selection (or inserts at the cursor) without shifting
    /// the starting offset.
    private struct PreSelection {
        let element: AXUIElement
        let location: Int
    }

    private static func capturePreSelection() -> PreSelection? {
        guard hasAccessibilityPermission() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        var rangeRef: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard r == .success, let rangeValue = rangeRef else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return PreSelection(element: element, location: range.location)
    }

    private static func setSelectedRange(_ element: AXUIElement, location: Int, length: Int) {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Asks macOS to register Dictator in the Accessibility list and pop the
    /// system permission dialog. Safe to call repeatedly — when the app is
    /// already trusted, it's a no-op; when it isn't, macOS adds the app to
    /// `System Settings → Privacy & Security → Accessibility` so the user has
    /// somewhere to enable it.
    ///
    /// Exposed publicly so the Settings UI can trigger registration without
    /// having to perform a (failing) AX call first.
    static func requestAccessibilityPrompt() {
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

    /// Posts a bare Return key event. Used by the per-mode "press Return
    /// after pasting" toggle so dictation into chat apps / search fields
    /// auto-submits. No modifiers — `.maskCommand` is explicitly cleared
    /// so a held modifier from somewhere else can't promote this into
    /// ⌘↩ (which means very different things app-to-app).
    private static func synthesizeReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let returnKey: CGKeyCode = 0x24 // ANSI Return

        let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true)
        down?.flags = []
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }
}
