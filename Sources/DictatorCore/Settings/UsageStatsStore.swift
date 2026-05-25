import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Lifetime usage counters surfaced on the About surface so the user
/// can see how much they've actually used the app.
///
/// **Why per-device counters, not a single global tally**: on macOS
/// the file lives in the synced folder alongside settings / vocab /
/// history. Two Macs on iCloud Drive can both be writing it, and a
/// naive "load → mutate global counter → write back" loses whichever
/// machine's write doesn't land last. Keying every counter by a
/// stable per-device UUID side-steps that: a machine only ever
/// mutates its own row, and `totals` sums across all rows on read.
/// Worst-case iCloud collision now just replays the *other* device's
/// counters from its next save — no data is destroyed.
///
/// iOS has no cross-device sync today (the file lives in the app
/// sandbox, not Files.app), but uses the same schema so a future
/// sync story drops in without a migration.
public struct UsageStats: Codable, Equatable, Sendable {
    public var dictationCount: Int = 0
    public var assistantCount: Int = 0
    public var wordsIn: Int = 0
    public var wordsOut: Int = 0

    public static let zero = UsageStats()

    public static func + (lhs: UsageStats, rhs: UsageStats) -> UsageStats {
        UsageStats(
            dictationCount: lhs.dictationCount + rhs.dictationCount,
            assistantCount: lhs.assistantCount + rhs.assistantCount,
            wordsIn: lhs.wordsIn + rhs.wordsIn,
            wordsOut: lhs.wordsOut + rhs.wordsOut
        )
    }
}

public enum UsageStatsMode: Sendable {
    case dictation
    case assistant
}

/// Per-device record persisted in `stats.json`. The `id` keys the map
/// in the on-disk envelope; everything else is descriptive metadata
/// so the file is meaningful when a curious user opens it in Finder.
struct UsageStatsDeviceRecord: Codable, Equatable, Sendable {
    /// Human-readable device name — `Host.current().localizedName` on
    /// macOS, `UIDevice.current.name` on iOS. Purely cosmetic; the UUID
    /// is the actual identity.
    var deviceName: String
    /// `"macOS"` or `"iOS"`, for at-a-glance hand-editing.
    var platform: String
    var stats: UsageStats
    var firstSeen: Date
    var lastUpdated: Date
}

/// File-backed store for `stats.json`. Lazily loads on first access,
/// merges this device's counter on every `record(...)`, writes
/// atomically. Lives next to history / vocab / settings.
@MainActor
@Observable
public final class UsageStatsStore {
    public static let shared = UsageStatsStore()

    /// Aggregated totals across every device record in the file —
    /// what the UI displays.
    public private(set) var totals: UsageStats = .zero

    /// Per-device id used as the key for this machine's row. Generated
    /// once and persisted in `UserDefaults`. We don't use the IOKit
    /// hardware UUID because (a) it requires extra IORegistry plumbing
    /// and (b) ad-hoc-rebuild churn on Macs already loses TCC grants
    /// keyed by signature, so an opaque stored UUID is no worse and
    /// dodges the IOKit dependency.
    private static let deviceIDKey = "DictatorUsageStats.deviceID.v1"

    /// Loaded device records, keyed by device UUID string.
    private var records: [String: UsageStatsDeviceRecord] = [:]
    private var deviceID: String = ""
    private var loaded = false

    private init() {}

    /// Increment this device's counters by the supplied amounts. Loads
    /// on first call. Failure to persist is logged but never thrown —
    /// stats are nice-to-have, not load-bearing for the dictation path.
    public func record(mode: UsageStatsMode, wordsIn: Int, wordsOut: Int) {
        ensureLoaded()
        var record = records[deviceID] ?? freshRecord()
        switch mode {
        case .dictation:
            record.stats.dictationCount += 1
        case .assistant:
            record.stats.assistantCount += 1
        }
        record.stats.wordsIn += max(0, wordsIn)
        record.stats.wordsOut += max(0, wordsOut)
        record.lastUpdated = Date()
        records[deviceID] = record
        recomputeTotals()
        persist()
    }

    /// Word count using the same whitespace-split convention the
    /// pipeline already uses for its display strings — splits on any
    /// whitespace run and drops empty pieces.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Force a fresh read from disk. Useful if an external process
    /// (another Mac via iCloud sync) wrote the file while the app was
    /// running. Not currently wired to a file watcher — the totals on
    /// About are read on-demand, and About isn't opened so often that
    /// staleness matters in practice.
    public func reload() {
        loaded = false
        ensureLoaded()
    }

    // MARK: - Load / save

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true

        if deviceID.isEmpty {
            if let stored = UserDefaults.standard.string(forKey: Self.deviceIDKey), !stored.isEmpty {
                deviceID = stored
            } else {
                let fresh = UUID().uuidString
                UserDefaults.standard.set(fresh, forKey: Self.deviceIDKey)
                deviceID = fresh
            }
        }

        let url = Self.storeURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.iso8601.decode(Envelope.self, from: data) {
            records = decoded.devices
        }
        recomputeTotals()
    }

    private func persist() {
        let envelope = Envelope(schemaVersion: 1, devices: records)
        guard let data = try? JSONEncoder.iso8601.encode(envelope) else { return }
        try? data.write(to: Self.storeURL(), options: .atomic)
    }

    private func recomputeTotals() {
        totals = records.values.reduce(UsageStats.zero) { $0 + $1.stats }
    }

    private func freshRecord() -> UsageStatsDeviceRecord {
        let now = Date()
        return UsageStatsDeviceRecord(
            deviceName: Self.currentDeviceName(),
            platform: Self.currentPlatform(),
            stats: .zero,
            firstSeen: now,
            lastUpdated: now
        )
    }

    // MARK: - Platform plumbing

    private static func storeURL() -> URL {
        let directory: URL
        #if canImport(AppKit)
        directory = SyncedStorage.directory
        #else
        // iOS: keep stats alongside the iOS history store, in the
        // sandbox's App Support directory. The shared synced folder
        // story doesn't exist on iOS yet (no Files.app picker, no
        // iCloud Drive integration), so picking a path users won't
        // ever browse to is the right call.
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("Dictator", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("stats.json")
    }

    private static func currentDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private static func currentPlatform() -> String {
        #if canImport(UIKit)
        return "iOS"
        #else
        return "macOS"
        #endif
    }

    // MARK: - On-disk envelope

    private struct Envelope: Codable {
        let schemaVersion: Int
        let devices: [String: UsageStatsDeviceRecord]
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
}
