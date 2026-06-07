import Foundation

/// Mirror of the mic-start NSLog lines, persisted to
/// `~/Library/Application Support/Dictator/mic-diagnostics.log`.
///
/// Two failure modes of the unified log made the Jun 2026 "stuck on
/// Connecting" forensics nearly impossible: info-level entries are
/// evicted from the log store within hours, and builds that ship their
/// code in `Dictator.debug.dylib` (Xcode debug-dylib builds) get NSLog
/// content redacted to `<private>` in `log show`. This file is the
/// durable copy: plain text, capped at ~256 KB, survives relaunches,
/// rebuilds, and log-store eviction. Local Application Support on
/// purpose — diagnostics shouldn't ride the synced-documents folder.
enum MicLog {
    /// Serial queue so appends from any actor never interleave and the
    /// caller (usually the main actor, mid-hotkey) never blocks on IO.
    private static let queue = DispatchQueue(label: "Dictator.MicLog", qos: .utility)

    private static let maxBytes: UInt64 = 256 * 1024
    private static let trimToBytes = 128 * 1024

    private static let fileURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Dictator", isDirectory: true)
            .appendingPathComponent("mic-diagnostics.log")
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// NSLog (unchanged Console / `log stream` behaviour) plus an append
    /// of the same line to the on-disk log. Fire-and-forget; a failed
    /// disk write drops the line rather than surfacing anywhere.
    nonisolated static func log(_ message: String) {
        NSLog("[Dictator] %@", message)
        let line = stampFormatter.string(from: Date()) + " " + message + "\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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

    /// Keep the newest `trimToBytes`, cut forward to a line boundary so
    /// the file never starts mid-line. Runs on `queue` via `append`.
    private static func trim() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let keep = data.suffix(trimToBytes)
        var tail = keep
        if let nl = keep.firstIndex(of: UInt8(ascii: "\n")) {
            tail = keep[keep.index(after: nl)...]
        }
        try? tail.write(to: fileURL, options: .atomic)
    }
}
