import AppKit
import CoreGraphics
import ApplicationServices

/// Lifts the current selection out of whatever app is frontmost by synthesising
/// ⌘C, waiting for the pasteboard `changeCount` to tick, and reading the result.
/// The previous pasteboard contents are snapshotted and restored, so the read is
/// invisible to anything else holding clipboard contents.
@MainActor
enum SelectionGrabber {
    enum GrabError: Error {
        case noAccessibility
    }

    /// Returns the freshly-copied selection, or nil if no selection was available
    /// (frontmost app had nothing selected, doesn't implement copy, etc.). Throws
    /// only when Accessibility permission is missing — that's a real config issue
    /// the user needs to address; an empty selection is a legitimate situation
    /// (e.g. "make me a list of 10 things here"). Restores the prior pasteboard
    /// either way.
    static func grab() async throws -> String? {
        guard TextInjector.hasAccessibilityPermission() else {
            throw GrabError.noAccessibility
        }

        let pasteboard = NSPasteboard.general
        let priorChangeCount = pasteboard.changeCount
        let priorSnapshot = snapshot(pasteboard)

        synthesizeCommandC()

        // Poll for up to ~300ms for the changeCount to tick — that's the signal
        // that something was copied. If it never ticks, the frontmost app either
        // had no selection or doesn't support copy.
        let deadline = Date().addingTimeInterval(0.3)
        while pasteboard.changeCount == priorChangeCount && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        defer { restore(priorSnapshot, to: pasteboard) }

        guard pasteboard.changeCount != priorChangeCount,
              let copied = pasteboard.string(forType: .string),
              !copied.isEmpty
        else {
            return nil
        }
        return copied
    }

    private static func synthesizeCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08 // ANSI 'C'
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [(NSPasteboard.PasteboardType, String)] {
        pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, String)? in
            for type in item.types {
                if let value = item.string(forType: type) { return (type, value) }
            }
            return nil
        } ?? []
    }

    private static func restore(_ items: [(NSPasteboard.PasteboardType, String)], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for (type, value) in items {
            pasteboard.setString(value, forType: type)
        }
    }
}
