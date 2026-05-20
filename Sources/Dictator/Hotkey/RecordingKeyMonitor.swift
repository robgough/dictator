import AppKit
import CoreGraphics

/// Intercepts Tab key-down events while installed and routes them to a
/// caller-supplied closure, *swallowing* the event so it doesn't also reach
/// whatever app is focused (which would otherwise insert a tab character into
/// the document the user is dictating into).
///
/// Implementation: a `CGEvent.tapCreate` at `.cgSessionEventTap` returning nil
/// for Tab suppresses delivery system-wide. A separate `addLocalMonitor`
/// covers the case where the user is focused in one of Dictator's own
/// windows (Settings, etc.) — the local monitor returns nil to drop Tab
/// before it reaches Dictator's responder chain.
///
/// Requires the same Accessibility permission Dictator already uses for
/// synthetic paste. Without it, `tapCreate` returns nil and we silently
/// skip the global hook — local cycling still works inside Dictator's own
/// windows.
@MainActor
final class RecordingKeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    /// The callback to invoke on a Tab press. Stored in a Sendable box so the
    /// non-main-thread CGEventTap callback can read it safely, and so we can
    /// reset it from `start` / `stop` without a data race on the closure
    /// itself.
    private let callbackBox = CallbackBox()

    /// Virtual keycode for Tab on macOS. Stable across keyboard layouts.
    private static let tabKeyCode: Int64 = 48

    func start(onTab: @escaping @MainActor () -> Void) {
        stop()
        callbackBox.set { Task { @MainActor in onTab() } }

        // Global suppression path: CGEventTap. Returns nil from tapCreate when
        // Accessibility isn't granted, in which case we fall back to local-only
        // monitoring — cycling still works when the user is focused in
        // Dictator's own windows but not when dictating into other apps.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(callbackBox).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                // Re-enable the tap if the system temporarily turned it off
                // (timeout from a long callback, or another tap raced us).
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                guard key == RecordingKeyMonitor.tabKeyCode else {
                    return Unmanaged.passUnretained(event)
                }
                // Tab during a recording — fire the action and swallow the
                // event so the focused app doesn't see it.
                if let userInfo {
                    let box = Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
                    box.invoke()
                }
                return nil
            },
            userInfo: pointer
        ) {
            self.tap = tap
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        // Local path for Tab inside Dictator's own windows. Returning nil
        // from the closure drops the event — no tab character inserted into
        // a text field in our settings UI either.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(Self.tabKeyCode) else { return event }
            self?.callbackBox.invoke()
            return nil
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        callbackBox.set(nil)
    }
}

/// Reference-typed box for the on-Tab closure. The CGEventTap callback runs
/// on a CGS thread, not the main actor, so we can't store the closure
/// directly on `@MainActor`-isolated state. The box's `invoke()` reads the
/// closure under a lock; the closure itself dispatches to MainActor.
private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var closure: (@Sendable () -> Void)?

    func set(_ closure: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.closure = closure
    }

    func invoke() {
        lock.lock()
        let c = closure
        lock.unlock()
        c?()
    }
}
