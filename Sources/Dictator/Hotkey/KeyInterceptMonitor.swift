import AppKit
import CoreGraphics

/// Intercepts one key's key-down events system-wide while installed, routes
/// them to a caller-supplied closure and *swallows* them so they don't also
/// reach the focused app. Two tenants, both owned by `DictationHUDController`:
///
/// - **Tab** while recording cycles the dictation mode. Without swallowing,
///   a tab character lands in the document being dictated into.
/// - **Escape** while the pipeline is cancellable aborts it. Without
///   swallowing, the same Escape also closes whatever popover, sheet or find
///   bar the user has open in the app they're dictating into — the
///   "I only meant to cancel the transcription" bug.
///
/// Implementation: a `CGEvent.tapCreate` at `.cgSessionEventTap` returning
/// nil for the key suppresses delivery system-wide. It needs the same
/// Accessibility permission Dictator already uses for synthetic paste;
/// without it `tapCreate` returns nil and we fall back per `fallback` — a
/// passive `addGlobalMonitor` that still fires the action but can't stop the
/// key reaching the app (Escape's pre-tap behaviour, better than no cancel at
/// all), or nothing (Tab: cycling while a tab character still lands would be
/// worse than not cycling, and the HUD hides the Tab hint in that case).
///
/// A separate `addLocalMonitor` covers Dictator's own windows when the tap
/// isn't running, honouring `localPolicy` — Tab is dropped so it can't tab
/// through a Settings form mid-cycle; Escape passes through so Dictator's
/// own Escape consumers (the assistant result window) keep working. While
/// the tap IS running it sees the event first and swallows it before any
/// local monitor does, for our windows too: during the few seconds a
/// pipeline is cancellable, Escape means "cancel", full stop.
@MainActor
final class KeyInterceptMonitor {
    /// Virtual keycodes, stable across keyboard layouts.
    enum Key: Int64 {
        case tab = 48
        case escape = 53
    }

    /// What to do when the event tap can't be created (no Accessibility).
    enum Fallback {
        /// `NSEvent.addGlobalMonitorForEvents` — fires the action, can't swallow.
        case passiveGlobalMonitor
        /// Skip the global hook; only Dictator's own windows are covered.
        case off
    }

    /// How the local (own-windows) monitor treats the key.
    enum LocalPolicy {
        case swallow
        case passThrough
    }

    private let key: Key
    private let fallback: Fallback
    private let localPolicy: LocalPolicy

    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Shared with the tap callback (which can't capture context) via
    /// `userInfo`. Holds the action closure and the tap itself, the latter so
    /// the callback can re-enable a tap the system switched off.
    private let box: TapBox

    init(key: Key, fallback: Fallback, localPolicy: LocalPolicy) {
        self.key = key
        self.fallback = fallback
        self.localPolicy = localPolicy
        self.box = TapBox(keyCode: key.rawValue)
    }

    func start(onKey: @escaping @MainActor () -> Void) {
        stop()
        box.setClosure { Task { @MainActor in onKey() } }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(box).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let box = Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue()
                // The system disables a tap whose callback ran long, or
                // after certain user-input storms. Re-enable, or every
                // later press would silently leak through to the app.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    box.reenable()
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      event.getIntegerValueField(.keyboardEventKeycode) == box.keyCode
                else { return Unmanaged.passUnretained(event) }
                // Our key — fire the action and swallow the event so the
                // focused app never sees it.
                box.invoke()
                return nil
            },
            userInfo: pointer
        ) {
            box.setTap(tap)
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else if fallback == .passiveGlobalMonitor {
            // Extract Sendable values synchronously — NSEvent is non-Sendable
            // and can't cross into the Task body.
            let keyCode = UInt16(key.rawValue)
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [box] event in
                guard event.keyCode == keyCode else { return }
                box.invoke()
            }
        }

        let keyCode = UInt16(key.rawValue)
        let swallowLocally = localPolicy == .swallow
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box] event in
            guard event.keyCode == keyCode else { return event }
            box.invoke()
            return swallowLocally ? nil : event
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = box.takeTap() {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        box.setClosure(nil)
    }
}

/// Reference-typed box shared with the C tap callback. The callback can't
/// capture Swift context, and may not run on the main actor, so the closure
/// and the tap port are read under a lock; the closure itself hops to
/// MainActor.
private final class TapBox: @unchecked Sendable {
    let keyCode: Int64
    private let lock = NSLock()
    private var closure: (@Sendable () -> Void)?
    private var tap: CFMachPort?

    init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    func setClosure(_ closure: (@Sendable () -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.closure = closure
    }

    func setTap(_ tap: CFMachPort?) {
        lock.lock(); defer { lock.unlock() }
        self.tap = tap
    }

    func takeTap() -> CFMachPort? {
        lock.lock(); defer { lock.unlock() }
        let t = tap
        tap = nil
        return t
    }

    func invoke() {
        lock.lock()
        let c = closure
        lock.unlock()
        c?()
    }

    func reenable() {
        lock.lock()
        let t = tap
        lock.unlock()
        if let t { CGEvent.tapEnable(tap: t, enable: true) }
    }
}
