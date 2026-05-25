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
public struct UsageStats: Equatable, Sendable {
    public var dictationCount: Int = 0
    public var assistantCount: Int = 0

    /// Words the user spoke during plain dictations (raw transcript
    /// count) and words actually delivered (final, post-pass count).
    /// Tracked separately from the assistant counters because the two
    /// flows answer different questions: dictation in/out tells you
    /// how much the cleanup passes trimmed; assistant in/out tells you
    /// how much the model expanded a short instruction into reply text.
    public var dictationWordsIn: Int = 0
    public var dictationWordsOut: Int = 0
    public var assistantWordsIn: Int = 0
    public var assistantWordsOut: Int = 0

    public static let zero = UsageStats()

    /// Total words across both flows. Kept as a derived value rather
    /// than a stored field so the per-mode counts are always the
    /// single source of truth.
    public var wordsIn: Int { dictationWordsIn + assistantWordsIn }
    public var wordsOut: Int { dictationWordsOut + assistantWordsOut }

    /// Average words per dictation, rounded to the nearest integer.
    /// `nil` when there are no dictations yet — divide-by-zero on
    /// an empty data set is meaningless; the UI just hides the row.
    public var averageDictationWords: Int? {
        guard dictationCount > 0 else { return nil }
        return Int((Double(dictationWordsOut) / Double(dictationCount)).rounded())
    }

    /// Average length of the user's spoken assistant instructions —
    /// "how chatty are my prompts". Output-side average (reply length)
    /// would be more about the model than the user, so we surface the
    /// input side instead.
    public var averageAssistantInstructionWords: Int? {
        guard assistantCount > 0 else { return nil }
        return Int((Double(assistantWordsIn) / Double(assistantCount)).rounded())
    }

    public static func + (lhs: UsageStats, rhs: UsageStats) -> UsageStats {
        UsageStats(
            dictationCount: lhs.dictationCount + rhs.dictationCount,
            assistantCount: lhs.assistantCount + rhs.assistantCount,
            dictationWordsIn: lhs.dictationWordsIn + rhs.dictationWordsIn,
            dictationWordsOut: lhs.dictationWordsOut + rhs.dictationWordsOut,
            assistantWordsIn: lhs.assistantWordsIn + rhs.assistantWordsIn,
            assistantWordsOut: lhs.assistantWordsOut + rhs.assistantWordsOut
        )
    }
}

extension UsageStats: Codable {
    private enum CodingKeys: String, CodingKey {
        case dictationCount, assistantCount
        case dictationWordsIn, dictationWordsOut
        case assistantWordsIn, assistantWordsOut
        // Legacy flat fields from the v1 schema (one combined wordsIn /
        // wordsOut per device). When present on decode we fold them
        // into the dictation buckets — dictation is the dominant flow,
        // and the inaccuracy is one-time per upgrade and visually
        // small once new counts accumulate on top.
        case wordsIn, wordsOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dictationCount = try c.decodeIfPresent(Int.self, forKey: .dictationCount) ?? 0
        assistantCount = try c.decodeIfPresent(Int.self, forKey: .assistantCount) ?? 0

        if let dIn = try c.decodeIfPresent(Int.self, forKey: .dictationWordsIn) {
            dictationWordsIn = dIn
            dictationWordsOut = try c.decodeIfPresent(Int.self, forKey: .dictationWordsOut) ?? 0
            assistantWordsIn = try c.decodeIfPresent(Int.self, forKey: .assistantWordsIn) ?? 0
            assistantWordsOut = try c.decodeIfPresent(Int.self, forKey: .assistantWordsOut) ?? 0
        } else {
            // v1 file: only flat wordsIn / wordsOut. Credit them to
            // dictation so the user's lifetime word total survives the
            // upgrade.
            let legacyIn = try c.decodeIfPresent(Int.self, forKey: .wordsIn) ?? 0
            let legacyOut = try c.decodeIfPresent(Int.self, forKey: .wordsOut) ?? 0
            dictationWordsIn = legacyIn
            dictationWordsOut = legacyOut
            assistantWordsIn = 0
            assistantWordsOut = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dictationCount, forKey: .dictationCount)
        try c.encode(assistantCount, forKey: .assistantCount)
        try c.encode(dictationWordsIn, forKey: .dictationWordsIn)
        try c.encode(dictationWordsOut, forKey: .dictationWordsOut)
        try c.encode(assistantWordsIn, forKey: .assistantWordsIn)
        try c.encode(assistantWordsOut, forKey: .assistantWordsOut)
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
    /// Overrides the platform-default storage directory. Set by
    /// `bootstrap(customDirectory:)`; nil means "fall back to the
    /// platform default" (synced folder on macOS, sandbox on iOS).
    private var customDirectory: URL?

    private init() {}

    /// Point the store at an explicit directory. Used on iOS when the
    /// user enables a shared folder via the security-scoped picker —
    /// any existing per-device records from other machines in the
    /// shared file are preserved, and this device's record is folded
    /// in (or kept fresh if it didn't exist there yet). Safe to call
    /// repeatedly: each call swaps the directory and reloads.
    public func bootstrap(customDirectory: URL?) {
        let existingLocalRecord: UsageStatsDeviceRecord?
        if loaded {
            existingLocalRecord = records[deviceID]
        } else {
            existingLocalRecord = nil
        }

        self.customDirectory = customDirectory
        loaded = false
        ensureLoaded()

        // If we had counters locally before the switch (most common:
        // the user has been dictating in sandbox mode and now connects
        // a shared folder), preserve them by writing this device's
        // pre-switch record into the new location. Other devices'
        // records that the new location already had stay intact.
        if let existingLocalRecord {
            let merged = mergeRecords(existing: records[deviceID], incoming: existingLocalRecord)
            records[deviceID] = merged
            recomputeTotals()
            persist()
        }
    }

    /// Increment this device's counters by the supplied amounts. Loads
    /// on first call. Failure to persist is logged but never thrown —
    /// stats are nice-to-have, not load-bearing for the dictation path.
    public func record(mode: UsageStatsMode, wordsIn: Int, wordsOut: Int) {
        ensureLoaded()
        var record = records[deviceID] ?? freshRecord()
        let safeIn = max(0, wordsIn)
        let safeOut = max(0, wordsOut)
        switch mode {
        case .dictation:
            record.stats.dictationCount += 1
            record.stats.dictationWordsIn += safeIn
            record.stats.dictationWordsOut += safeOut
        case .assistant:
            record.stats.assistantCount += 1
            record.stats.assistantWordsIn += safeIn
            record.stats.assistantWordsOut += safeOut
        }
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

        let url = storeURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.iso8601.decode(Envelope.self, from: data) {
            records = decoded.devices
        }
        recomputeTotals()
    }

    private func persist() {
        let envelope = Envelope(schemaVersion: 1, devices: records)
        guard let data = try? JSONEncoder.iso8601.encode(envelope) else { return }
        try? data.write(to: storeURL(), options: .atomic)
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

    private func storeURL() -> URL {
        let directory = customDirectory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("stats.json")
    }

    private static func defaultDirectory() -> URL {
        #if canImport(AppKit)
        return SyncedStorage.directory
        #else
        // iOS: by default keep stats in the app sandbox alongside the
        // history store. The shared-folder opt-in (Settings → Shared
        // folder on iOS) overrides this via `bootstrap(customDirectory:)`.
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Dictator", isDirectory: true)
        #endif
    }

    /// Combines two per-device records (same deviceID) by taking the
    /// component-wise *max* of each counter and the latest timestamps.
    /// Max-rather-than-sum guards against the obvious double-count
    /// failure when the same record exists on both sides of a switch:
    /// counters are monotonically non-decreasing per device, so the
    /// higher number is always the more recent truth.
    private func mergeRecords(existing: UsageStatsDeviceRecord?, incoming: UsageStatsDeviceRecord) -> UsageStatsDeviceRecord {
        guard let existing else { return incoming }
        let stats = UsageStats(
            dictationCount: max(existing.stats.dictationCount, incoming.stats.dictationCount),
            assistantCount: max(existing.stats.assistantCount, incoming.stats.assistantCount),
            dictationWordsIn: max(existing.stats.dictationWordsIn, incoming.stats.dictationWordsIn),
            dictationWordsOut: max(existing.stats.dictationWordsOut, incoming.stats.dictationWordsOut),
            assistantWordsIn: max(existing.stats.assistantWordsIn, incoming.stats.assistantWordsIn),
            assistantWordsOut: max(existing.stats.assistantWordsOut, incoming.stats.assistantWordsOut)
        )
        return UsageStatsDeviceRecord(
            deviceName: incoming.deviceName,
            platform: incoming.platform,
            stats: stats,
            firstSeen: min(existing.firstSeen, incoming.firstSeen),
            lastUpdated: max(existing.lastUpdated, incoming.lastUpdated)
        )
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
