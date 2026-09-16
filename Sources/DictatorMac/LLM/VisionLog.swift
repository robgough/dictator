import Foundation

/// Durable timings for the window-vision read, written to
/// `~/Library/Application Support/Dictator/vision-diagnostics.log`.
///
/// Same reasoning as `MicLog`, and for the same two reasons: info-level
/// entries leave the unified log store within hours, and builds that ship
/// their code in `Dictator.debug.dylib` get NSLog *content* redacted to
/// `<private>` in `log show` — which would make an instrumented run produce a
/// file full of timestamps and no numbers. The question this log exists to
/// answer ("did the read finish while the user was still speaking?") needs a
/// handful of runs across a session, so it has to survive relaunches too.
///
/// Its own file rather than a few more lines in `mic-diagnostics.log`: that
/// one is the first thing read when a mic start stalls, and a couple of vision
/// timings per dictation would bury the thing it's for.
///
/// Diagnostics never take the app down and never block the caller — every
/// write is fire-and-forget on a utility queue, and a failed write drops the
/// line.
enum VisionLog {
    private static let queue = DispatchQueue(label: "Dictator.VisionLog", qos: .utility)
    private static let maxBytes: UInt64 = 128 * 1024

    private static let fileURL: URL = {
        AppSupportPaths.dictator.appendingPathComponent("vision-diagnostics.log")
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// NSLog (so `log stream` still shows it on a normal build) plus an append
    /// of the same line to the on-disk log.
    nonisolated static func log(_ message: String) {
        NSLog("[Dictator][Vision] %@", message)
        let line = stampFormatter.string(from: Date()) + " " + message + "\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if end + UInt64(data.count) > maxBytes { trim() }
        } catch {
            // Diagnostics must never take the app down.
        }
    }

    /// Keep the newest half when the file outgrows its cap. Whole lines only —
    /// a half-line at the head is the kind of thing that wastes a minute
    /// during the reading.
    private static func trim() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let keep = data.suffix(Int(maxBytes) / 2)
        guard let newlineIndex = keep.firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? keep[(newlineIndex + 1)...].write(to: fileURL, options: .atomic)
    }
}
