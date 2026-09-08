import AppKit
import CoreGraphics

/// Renders one of *our own* windows to a PNG on disk, plus the small amount of
/// run-loop plumbing a scripted capture needs. Developer-only: nothing here is
/// reachable outside `ScreenshotMode` (see `ScreenshotMode` in DictatorCore).
///
/// Two techniques, tried in order:
///
///  1. `CGWindowListCreateImage` scoped to a single window id. Capturing a
///     window owned by the *calling* process is exempt from the Screen
///     Recording TCC check, so this works with no grant — but the API is
///     deprecated and has historically started returning empty images, hence
///     the emptiness check and the fallback.
///  2. `NSView.cacheDisplay(in:to:)` against the window's theme frame (the
///     `contentView`'s superview, so the title bar and traffic lights are
///     included). Always available, but visual-effect materials render without
///     their behind-window blur.
///
/// Both paths produce a backing-scale (Retina, 2×) bitmap; when the window
/// happens to sit on a 1× display the image is re-rendered at 2× explicitly so
/// the shots are consistent.
@MainActor
enum ScreenshotWindowCapture {

    // MARK: - Run-loop settling

    /// Pump AppKit for `seconds` so SwiftUI can lay out, animate and settle.
    ///
    /// It has to drain `NSApp`'s *event* queue, not just spin the run loop: the
    /// capture never returns to `NSApplication.run()`, so anything delivered as
    /// an NSEvent — app activation and window key changes among them — would
    /// otherwise sit in the queue undelivered, and every window would render
    /// with inactive chrome.
    static func settle(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.02))
            if let event = NSApp.nextEvent(matching: .any, until: slice, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    // MARK: - Window lookup

    /// First on-screen window matching `predicate`, ignoring the invisible
    /// helper windows AppKit and SwiftUI keep around.
    static func window(where predicate: (NSWindow) -> Bool) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && predicate($0) }
    }

    /// Put a window fully on-screen at a fixed size, so captures are
    /// reproducible and never clipped by the screen edge.
    static func place(_ window: NSWindow, size: NSSize) {
        // Drop any frame-autosave name first: resizing a window that saves its
        // frame would write into the user's real preferences and move their own
        // copy's window next time they open it.
        window.setFrameAutosaveName("")
        window.setContentSize(size)
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let x = visible.minX + max(0, (visible.width - frame.width) / 2)
        let y = visible.minY + max(0, (visible.height - frame.height) / 2)
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: - Capture

    /// Capture `window` and write a PNG to `path`. Returns the pixel size on
    /// success, nil on failure (the caller logs and exits non-zero).
    @discardableResult
    static func capture(_ window: NSWindow, to path: String) -> NSSize? {
        window.displayIfNeeded()
        settle(seconds: 0.2)

        let image = cgImageViaWindowList(window) ?? cgImageViaCacheDisplay(window)
        guard let image else {
            NSLog("[Screenshot] Both capture paths failed for window '\(window.title)'")
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("[Screenshot] PNG encoding failed")
            return nil
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[Screenshot] Couldn't write \(path): \(error)")
            return nil
        }
        return NSSize(width: image.width, height: image.height)
    }

    /// Technique 1 — own-window `CGWindowListCreateImage`, resolved at runtime.
    ///
    /// The symbol is marked *unavailable* (not merely deprecated) in the macOS
    /// 27 SDK — the compiler refuses a direct call — but it is still exported by
    /// CoreGraphics and still exempt from the Screen Recording check for a
    /// window the calling process owns. `dlsym` is the only way to reach it
    /// without a ScreenCaptureKit grant we deliberately don't ask for. Returns
    /// nil (and we fall back) whenever the symbol is gone or the window server
    /// hands back an empty image.
    private typealias WindowListCreateImage = @convention(c) (
        CGRect, UInt32, CGWindowID, UInt32
    ) -> Unmanaged<CGImage>?

    private static let windowListCreateImage: WindowListCreateImage? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(sym, to: WindowListCreateImage.self)
    }()

    private static func cgImageViaWindowList(_ window: NSWindow) -> CGImage? {
        let id = CGWindowID(window.windowNumber)
        guard id != 0, let create = windowListCreateImage else { return nil }
        // kCGWindowListOptionIncludingWindow = 1 << 3
        // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        let listOption: UInt32 = 1 << 3
        let imageOption: UInt32 = (1 << 0) | (1 << 3)
        let nullRect = CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 0, height: 0)
        guard let image = create(nullRect, listOption, id, imageOption)?.takeRetainedValue(),
              image.width > 100, image.height > 100,
              !isBlank(image)
        else {
            NSLog("[Screenshot] CGWindowListCreateImage produced nothing usable; falling back to cacheDisplay")
            return nil
        }
        NSLog("[Screenshot] Captured via CGWindowListCreateImage (\(image.width)×\(image.height))")
        return image
    }

    /// Technique 2 — `cacheDisplay` on the theme frame, forced to 2× when the
    /// window's own backing scale is lower.
    private static func cgImageViaCacheDisplay(_ window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview else { return nil }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard var image = rep.cgImage else { return nil }
        if CGFloat(image.width) < bounds.width * 2 {
            image = upscaled(image, to: CGSize(width: bounds.width * 2, height: bounds.height * 2)) ?? image
        }
        NSLog("[Screenshot] Captured via cacheDisplay (\(image.width)×\(image.height))")
        return image
    }

    /// Nearest-neighbour-free redraw at a larger pixel size. Only used when the
    /// capture landed on a 1× display, which shouldn't normally happen.
    private static func upscaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let space = image.colorSpace,
              let ctx = CGContext(data: nil,
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// True when every sampled pixel is identical — the signature of a capture
    /// the window server refused to fill in.
    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        guard length > 4 else { return true }
        let stride = max(4, (length / 400) & ~3)
        var first: UInt32?
        var index = 0
        while index + 3 < length {
            let pixel = UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
            if let first {
                if pixel != first { return false }
            } else {
                first = pixel
            }
            index += stride
        }
        return true
    }

    // MARK: - Process plumbing

    /// Hard watchdog: a capture that hangs must not leave a stray process
    /// behind. Runs off the main queue so a wedged main thread can't defer it.
    static func startWatchdog(seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            NSLog("[Screenshot] Watchdog fired after \(Int(seconds))s — exiting")
            exit(2)
        }
    }

    /// Bring the app to the front and make `window` key, retrying until AppKit
    /// agrees. A capture launched straight from a shell starts out inactive,
    /// and an inactive app draws inactive chrome — grey traffic lights,
    /// untinted switches — which is not what a marketing screenshot wants.
    @discardableResult
    static func activate(_ window: NSWindow, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            settle(seconds: 0.25)
            if NSApp.isActive && window.isKeyWindow { return true }
        }
        NSLog("[Screenshot] Window never became active (active=\(NSApp.isActive) key=\(window.isKeyWindow)) — chrome will render inactive")
        return false
    }

    /// Light appearance for every shot, so the six match the light-mode iOS
    /// thumbnails already on the site.
    static func forceLightAppearance() {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    static func finish(_ size: NSSize?, path: String?) -> Never {
        if let size, let path {
            NSLog("[Screenshot] Wrote \(path) at \(Int(size.width))×\(Int(size.height))")
            exit(0)
        }
        NSLog("[Screenshot] Capture failed")
        exit(1)
    }
}
