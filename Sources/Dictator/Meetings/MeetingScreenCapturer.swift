import ScreenCaptureKit
import CoreMedia
import CoreImage
import CoreVideo
import AppKit

/// Window-scoped screen capture for meetings. Runs an `SCStream` at a low frame
/// rate against the meeting app's window for the duration of the recording, and
/// keeps only *keyframes* — frames that differ significantly from the last kept
/// one and then hold steady — as HEICs in the meeting's local `screenshots/`
/// folder. A talking-head grid produces ~nothing (tiny hash deltas); a slide
/// change produces exactly one. That's the difference between a dozen useful
/// stills and a 500 MB frame dump.
///
/// Window-scoped, never whole-display: we only ever capture the call window, so
/// the user's other windows, notifications, and second screen are never seen.
/// If no meeting window can be resolved we capture NOTHING (rather than silently
/// grabbing the whole screen) — the conservative default for v1.
///
/// Owned by `MeetingSession`, started after the audio recorders and stopped
/// alongside them. The heavy per-frame work (downscale, hash, encode) runs on
/// the stream's own serial sample-handler queue, off the main actor.
@MainActor
@Observable
final class MeetingScreenCapturer {
    enum StartResult {
        case started(windowTitle: String?)
        case noWindow
        case failed(String)
    }

    /// A selectable capture target — one on-screen meeting/browser window. The
    /// `windowID` is the stable handle the picker round-trips through.
    struct CaptureTarget: Identifiable, Hashable, Sendable {
        let windowID: CGWindowID
        let appName: String
        let windowTitle: String
        var id: CGWindowID { windowID }
        var label: String { windowTitle.isEmpty ? appName : "\(appName) — \(windowTitle)" }
    }

    /// Capture cadence — 1 fps is ample for slides/demos and keeps the encode
    /// load trivial. Tunable; see the keyframe constants in `FrameSink`.
    private static let captureFPS: Int32 = 1
    /// Cap the captured long edge so HEICs stay small while text stays OCR-able
    /// for the v2 Vision pass. ~2560 keeps a shared 16:9 deck readable.
    private static let maxLongEdgePixels: CGFloat = 2560

    /// The window currently being captured — observable so the live UI can show
    /// "Capturing: Zoom — Screen Share" and drive the change menu's checkmark.
    private(set) var currentTarget: CaptureTarget?
    /// File URL of the most recently kept keyframe — observable so the live UI
    /// can show a thumbnail of the last thing captured.
    private(set) var latestScreenshotURL: URL?
    private(set) var isCapturing = false

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var sink: FrameSink?
    @ObservationIgnored private var folder: URL?

    /// Start capturing the meeting window. `preferredBundleID` biases window
    /// selection toward the app that was frontmost at record start. Never
    /// throws — capture is best-effort and must not fail the meeting.
    func start(folder: URL, preferredBundleID: String?) async -> StartResult {
        self.folder = folder
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = Self.pickWindow(from: content.windows, preferredBundleID: preferredBundleID) else {
                return .noWindow
            }
            try await beginStream(on: window, folder: folder)
            return .started(windowTitle: window.title)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// On-screen meeting/browser windows the user can switch capture to. Empty
    /// when Screen Recording isn't granted (the query throws) — the UI reads
    /// that as the permission prompt.
    func availableTargets() async -> [CaptureTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return [] }
        return Self.hostWindows(from: content.windows).map {
            CaptureTarget(
                windowID: $0.windowID,
                appName: $0.owningApplication?.applicationName ?? "—",
                windowTitle: $0.title ?? ""
            )
        }
    }

    /// Retarget capture to a chosen window. Reuses the running stream
    /// (`updateContentFilter` keeps the keyframe state intact, so the count and
    /// dedup carry across the switch); starts a fresh stream if none was running
    /// (auto-resolution found nothing and the user picked manually).
    @discardableResult
    func switchTo(windowID: CGWindowID) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ), let window = content.windows.first(where: { $0.windowID == windowID }) else { return false }
        do {
            if let stream {
                try await stream.updateContentFilter(SCContentFilter(desktopIndependentWindow: window))
                try await stream.updateConfiguration(Self.configuration(for: window.frame.size))
                setTarget(window)
            } else if let folder {
                try await beginStream(on: window, folder: folder)
            } else {
                return false
            }
            NSLog("[Dictator] Screenshots: switched capture to '\(window.title ?? "—")'")
            return true
        } catch {
            NSLog("[Dictator] Screenshots: switch failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Stop the stream and flush the index. Returns the captured keyframes.
    @discardableResult
    func stop() async -> MeetingScreenshotIndex {
        isCapturing = false
        guard let stream else { return MeetingScreenshotIndex() }
        try? await stream.stopCapture()
        self.stream = nil
        let index = sink?.finish() ?? MeetingScreenshotIndex()
        sink = nil
        return index
    }

    // MARK: - Stream bring-up

    private func beginStream(on window: SCWindow, folder: URL) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let sink = self.sink ?? FrameSink(folder: folder, onKeep: { [weak self] url in
            Task { @MainActor in self?.latestScreenshotURL = url }
        })
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: window.frame.size), delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()
        self.stream = stream
        self.sink = sink
        self.isCapturing = true
        setTarget(window)
        NSLog("[Dictator] Screenshots: capturing window '\(window.title ?? "—")' of \(window.owningApplication?.bundleIdentifier ?? "?")")
    }

    private func setTarget(_ window: SCWindow) {
        currentTarget = CaptureTarget(
            windowID: window.windowID,
            appName: window.owningApplication?.applicationName ?? "—",
            windowTitle: window.title ?? ""
        )
    }

    private static func configuration(for pointSize: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: captureFPS)
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let (w, h) = captureSize(for: pointSize)
        config.width = w
        config.height = h
        return config
    }

    // MARK: - Window selection

    /// On-screen windows owned by a known host app (meeting client or browser),
    /// large enough to be a call rather than a utility HUD.
    private static func hostWindows(from windows: [SCWindow]) -> [SCWindow] {
        windows.filter { window in
            guard window.isOnScreen,
                  let bundleID = window.owningApplication?.bundleIdentifier,
                  MeetingHostApps.hostBundleIDs.contains(bundleID) else { return false }
            return window.frame.width >= 320 && window.frame.height >= 240
        }
    }

    /// Pick the meeting window to scope to: prefer the frontmost app's, then the
    /// largest. nil when nothing host-owned is on screen — we never default to
    /// whole-display capture.
    private static func pickWindow(from windows: [SCWindow], preferredBundleID: String?) -> SCWindow? {
        let hosts = hostWindows(from: windows)
        guard !hosts.isEmpty else { return nil }
        func area(_ w: SCWindow) -> CGFloat { w.frame.width * w.frame.height }
        if let preferredBundleID {
            let preferred = hosts
                .filter { $0.owningApplication?.bundleIdentifier == preferredBundleID }
                .max(by: { area($0) < area($1) })
            if let preferred { return preferred }
        }
        return hosts.max(by: { area($0) < area($1) })
    }

    /// Pixel size for the capture: 2× the window's point size (retina-ish
    /// crispness for text) capped at `maxLongEdgePixels`.
    private static func captureSize(for pointSize: CGSize) -> (Int, Int) {
        var w = max(pointSize.width, 1) * 2
        var h = max(pointSize.height, 1) * 2
        let longEdge = max(w, h)
        if longEdge > maxLongEdgePixels {
            let k = maxLongEdgePixels / longEdge
            w *= k
            h *= k
        }
        return (Int(w.rounded()), Int(h.rounded()))
    }
}

/// The off-main frame consumer: hashes each frame on the stream's serial queue,
/// keeps debounced keyframes, writes HEICs + the index. `@unchecked Sendable`
/// because all mutable state is touched only on `queue` (SCK delivers frames
/// there, and `finish()` reads back through a `queue.sync`).
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "net.robgough.dictator.screenshots")

    // Keyframe tuning — deliberately conservative defaults (validated against
    // real calls is a TODO; these err toward fewer, more-distinct frames).
    /// Hamming distance (of the 64-bit aHash) that counts as a "real" change.
    private let changeThreshold = 10
    /// A change must persist this long before it's committed — skips the blur
    /// of scrolling/animation/slide transitions.
    private let debounceSeconds: TimeInterval = 2.0
    /// Floor between two keeps, and a per-minute ceiling — backstops against a
    /// busy screen (video, ticker) turning into a frame dump.
    private let minKeepInterval: TimeInterval = 1.5
    private let perMinuteCap = 8

    private let folder: URL
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let recordingStart = Date()
    /// Called on the sink's queue each time a keyframe lands — the capturer
    /// hops it to the main actor to update the live "latest screenshot" view.
    private let onKeep: (@Sendable (URL) -> Void)?

    private var lastKeptHash: UInt64?
    private var lastKeptAt: Date?
    private var pendingHash: UInt64?
    private var pendingSince: Date?
    private var recentKeeps: [Date] = []
    private var records: [ScreenshotRecord] = []

    init(folder: URL, onKeep: (@Sendable (URL) -> Void)? = nil) {
        self.folder = folder
        self.onKeep = onKeep
        super.init()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // SCStreamDelegate — a stopped/errored stream just ends capture; nothing to
    // recover, the frames already on disk stand.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Dictator] Screenshots: stream stopped with error: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        process(pixelBuffer)
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard let hash = averageHash(pixelBuffer) else { return }

        // First frame establishes the baseline without keeping — a meeting
        // usually opens on the (non-shared) call window, not content worth a still.
        guard let kept = lastKeptHash else {
            lastKeptHash = hash
            lastKeptAt = now
            return
        }

        guard hamming(hash, kept) >= changeThreshold else {
            // Back to (or still on) the last kept view — no pending change.
            pendingHash = nil
            pendingSince = nil
            return
        }

        // A significant change. Require it to hold steady for the debounce
        // window before committing, so transitions don't each become a frame.
        if let pending = pendingHash, hamming(hash, pending) < changeThreshold {
            if let since = pendingSince, now.timeIntervalSince(since) >= debounceSeconds {
                keep(pixelBuffer, hash: hash, at: now)
            }
        } else {
            pendingHash = hash
            pendingSince = now
        }
    }

    private func keep(_ pixelBuffer: CVPixelBuffer, hash: UInt64, at now: Date) {
        if let last = lastKeptAt, now.timeIntervalSince(last) < minKeepInterval { return }
        recentKeeps = recentKeeps.filter { now.timeIntervalSince($0) < 60 }
        guard recentKeeps.count < perMinuteCap else { return }

        let offset = now.timeIntervalSince(recordingStart)
        let filename = String(format: "%04d-%@.heic", records.count + 1, Self.clock(offset))
        let url = folder.appendingPathComponent(filename)
        guard writeHEIC(pixelBuffer, to: url) else { return }

        lastKeptHash = hash
        lastKeptAt = now
        pendingHash = nil
        pendingSince = nil
        recentKeeps.append(now)
        records.append(ScreenshotRecord(
            filename: filename,
            offsetSeconds: offset,
            hash: String(hash, radix: 16),
            capturedAt: now,
            ocrText: nil
        ))
        writeIndex()  // incremental, so a crash keeps what we've captured
        onKeep?(url)
    }

    /// Flush the index and hand back the keyframes. Synchronised on `queue` so
    /// it sees every frame the stream delivered before `stopCapture` returned.
    func finish() -> MeetingScreenshotIndex {
        queue.sync {
            writeIndex()
            return MeetingScreenshotIndex(screenshots: records)
        }
    }

    private func writeIndex() {
        let index = MeetingScreenshotIndex(screenshots: records)
        let url = folder.appendingPathComponent(MeetingStorage.screenshotIndexFilename)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Image work

    /// 64-bit average hash (8×8 grayscale, bit set where a cell is brighter than
    /// the frame mean). Cheap, rotation/scale-stable enough for "did the slide
    /// change", which is all we need.
    private func averageHash(_ pixelBuffer: CVPixelBuffer) -> UInt64? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: 8.0 / extent.width, y: 8.0 / extent.height
        ))

        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        ciContext.render(
            scaled,
            toBitmap: &pixels,
            rowBytes: 8 * 4,
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        var luminance = [Double](repeating: 0, count: 64)
        var sum = 0.0
        for i in 0..<64 {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            luminance[i] = l
            sum += l
        }
        let mean = sum / 64
        var hash: UInt64 = 0
        for i in 0..<64 where luminance[i] >= mean {
            hash |= (UInt64(1) << UInt64(i))
        }
        return hash
    }

    private func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    private func writeHEIC(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Bool {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7
        ]
        guard let data = try? ciContext.heifRepresentation(
            of: image, format: .RGBA8, colorSpace: colorSpace, options: options
        ) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `HHhMMmSSs` from a second offset, for sortable, human-readable filenames.
    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02dh%02dm%02ds", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// SCK delivers idle/blank frames between real ones; only `.complete` frames
    /// carry new pixels worth hashing.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}
