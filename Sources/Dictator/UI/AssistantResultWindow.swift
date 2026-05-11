import AppKit
import SwiftUI

/// Pops up a readable window with the assistant's output whenever the result
/// lands on the clipboard rather than getting pasted in place — either because
/// the user asked for a draft (DRAFT mode) or because pasting failed and we
/// fell back to copy-only. The clipboard is already populated by the time this
/// shows, so the window is purely a "you can read this right now" affordance.
@MainActor
final class AssistantResultController {
    private var window: NSWindow?

    func show(text: String, instruction: String) {
        let window = ensureWindow()
        let root = AssistantResultView(
            text: text,
            instruction: instruction,
            onCopy: { [weak self] in self?.copyToClipboard(text) },
            onClose: { [weak self] in self?.close() }
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Assistant Result"
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.minSize = NSSize(width: 420, height: 280)
        window = w
        return w
    }
}

private struct AssistantResultView: View {
    let text: String
    let instruction: String
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var copyFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !instruction.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.indigo)
                        .font(.system(size: 12, weight: .semibold))
                    Text("\u{201C}\(instruction)\u{201D}")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text("Already on your clipboard — \u{2318}V to paste anywhere")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copyFeedback ? "Copied" : "Copy again") {
                    onCopy()
                    copyFeedback = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copyFeedback = false
                    }
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 280)
    }
}
