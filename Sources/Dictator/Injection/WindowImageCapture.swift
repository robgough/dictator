import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import AppKit

/// One-shot capture of the *focused window* as a `CGImage`, scoped to a single
/// window (never the whole display) through ScreenCaptureKit's screenshot API.
/// Feeds `WindowVisionContext`, which reads proper-noun spellings off the image
/// that the Accessibility text reads can't reach — names sitting outside the
/// field being typed into, or in apps that don't expose their text tree at all
/// (Electron with accessibility off, canvas editors, terminals).
///
/// The target is the frontmost application's largest on-screen window. When a
/// dictation fires, Dictator is a non-activating menu-bar app, so the frontmost
/// application is the user's actual target — the same assumption the rest of the
/// pipeline makes (mode resolution, AX focus). Returns nil if Screen Recording
/// isn't granted, nothing suitable is on screen, or the capture fails; callers
/// treat nil as "no vision context this run", never an error.
enum WindowImageCapture {
    /// Long-edge cap for the captured pixels. The vision model's prefill cost
    /// scales with image resolution, and field testing showed a ~640–1024 px
    /// grab is both faster AND no less accurate than a full-res one (the text
    /// stays legible at this size). Downscaling happens in-capture via the
    /// stream configuration, so no extra resample pass is needed.
    static let maxLongEdgePixels: CGFloat = 1024

    /// Smallest window we'll bother with — skips utility HUDs, find bars, and
    /// notification chrome that would only add noise.
    private static let minWindowSize = CGSize(width: 200, height: 120)

    static func captureFocusedWindow() async -> CGImage? {
        guard ScreenRecordingPermission.hasAccess() else {
            NSLog("[Dictator] Window vision: no Screen Recording permission — skipped.")
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = focusedForeignWindow(from: content.windows) else {
                NSLog("[Dictator] Window vision: no capturable window (none on screen that isn't our own).")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration(for: window.frame.size)
            )
            return image
        } catch {
            NSLog("[Dictator] Window vision: capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The window the user is actually looking at: the top-most on-screen,
    /// normal-layer window that ISN'T one of Dictator's own.
    ///
    /// Deliberately NOT "the frontmost app's window". After an assistant turn the
    /// result window activates (`NSApp.activate` + `makeKeyAndOrderFront`), so
    /// Dictator becomes the frontmost app — and a frontmost-app lookup then finds
    /// only our floating result window (which sits above layer 0, so it doesn't
    /// even match the layer-0 filter) and returns nothing on every follow-up.
    /// Resolving the top-most *foreign* window from the z-ordered window list
    /// instead captures the user's content behind our panel, first turn and
    /// follow-ups alike.
    private static func focusedForeignWindow(from windows: [SCWindow]) -> SCWindow? {
        let ourPID = NSRunningApplication.current.processIdentifier
        if let id = topmostForeignWindowID(excludingPID: ourPID),
           let match = windows.first(where: { $0.windowID == id }) {
            return match
        }
        // Fallback (window list unavailable): largest foreign on-screen window.
        return windows
            .filter {
                ($0.owningApplication?.processID ?? ourPID) != ourPID
                    && $0.isOnScreen
                    && $0.windowLayer == 0
                    && $0.frame.width >= minWindowSize.width
                    && $0.frame.height >= minWindowSize.height
            }
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    /// CGWindowID of the front-most on-screen, normal-layer window not owned by
    /// `pid`, walking the window list in front-to-back z-order. Excludes menu
    /// bars / HUDs (non-zero layer) and tiny utility windows.
    private static func topmostForeignWindowID(excludingPID pid: pid_t) -> CGWindowID? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in infoList {  // front-to-back
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, ownerPID != pid,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minWindowSize.width, bounds.height >= minWindowSize.height
            else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    private static func configuration(for pointSize: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let (w, h) = captureSize(for: pointSize)
        config.width = w
        config.height = h
        return config
    }

    /// Pixel size for the capture: the window's point size, scaled down so the
    /// long edge fits `maxLongEdgePixels`. Aspect ratio is preserved (both edges
    /// scaled by the same factor) so the window fills the frame without
    /// letterboxing. No 2× retina factor — unlike the meeting capturer's stills,
    /// the model wants legible text, not crisp pixels, and smaller is faster.
    private static func captureSize(for pointSize: CGSize) -> (Int, Int) {
        var w = max(pointSize.width, 1)
        var h = max(pointSize.height, 1)
        let longEdge = max(w, h)
        if longEdge > maxLongEdgePixels {
            let k = maxLongEdgePixels / longEdge
            w *= k
            h *= k
        }
        return (Int(w.rounded()), Int(h.rounded()))
    }
}
