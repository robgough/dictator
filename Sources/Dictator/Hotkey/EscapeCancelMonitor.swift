import AppKit

/// Watches `.keyDown` events globally and locally for the Escape key while
/// installed. Used to let the user cancel a long-running pipeline from any
/// app, mirroring what the HUD's hover-cancel button already does.
///
/// `addGlobalMonitorForEvents` is passive — the Escape still reaches the
/// focused app, so other apps' Escape semantics (close popovers etc.) are
/// unaffected. The trade-off is that an Escape pressed for an unrelated
/// reason while a pipeline is running will also cancel the pipeline; we
/// only install the monitor while the pipeline is genuinely interruptible
/// (`PipelineState.canCancel == true`), which keeps the window short.
///
/// Like `ModifierKeyMonitor`, this needs Input Monitoring permission to
/// receive events from other apps. Without it, global events don't fire
/// but the local one still catches Escape inside Dictator's own windows.
@MainActor
final class EscapeCancelMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onEscape: (() -> Void)?

    /// Virtual keycode for Escape on macOS. Stable across keyboard layouts.
    private static let escapeKeyCode: UInt16 = 53

    func start(onEscape: @escaping () -> Void) {
        stop()
        self.onEscape = onEscape

        // Extract Sendable values synchronously — NSEvent is non-Sendable and
        // can't cross into the @Sendable Task body, same shape as
        // ModifierKeyMonitor.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode
            Task { @MainActor [weak self] in
                self?.handle(keyCode: key)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode
            Task { @MainActor [weak self] in
                self?.handle(keyCode: key)
            }
            // Pass the event through — we don't want to swallow Escape from
            // legitimate consumers inside Dictator (e.g. closing the
            // assistant result window, which has its own Escape shortcut).
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        onEscape = nil
    }

    private func handle(keyCode: UInt16) {
        guard keyCode == Self.escapeKeyCode else { return }
        onEscape?()
    }
}
