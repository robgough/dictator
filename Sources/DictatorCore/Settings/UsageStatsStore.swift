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
    /// Seconds of speech actually transcribed across every dictation,
    /// measured after silence trimming. Stored rather than derived because
    /// nothing else on disk knows how long a recording was — and without it
    /// there is no honest words-per-minute figure, only a guess.
    public var dictationSeconds: Double = 0
    /// Delivered words from *only* those dictations that also contributed to
    /// `dictationSeconds`.
    ///
    /// Exists because the two are not the same population. Recording duration
    /// was added long after the word counts, so on any install that predates it
    /// `dictationWordsOut` covers thousands of dictations while
    /// `dictationSeconds` covers only the recent ones — dividing one by the
    /// other produced a real-world reading of 33,116 words a minute. The same
    /// skew appears whenever a second Mac is running an older build, or when a
    /// recording's duration is rejected by the sanity clamp below.
    ///
    /// Defaults to 0, so existing installs start this metric fresh rather than
    /// inheriting a ratio that was never true.
    public var dictationWordsOutTimed: Int = 0
    public var assistantWordsIn: Int = 0
    public var assistantWordsOut: Int = 0

    /// Combined LLM token usage across every on-device call — the
    /// dictation cleanup passes (format / grammar / structure) and
    /// every assistant turn. Kept as a single combined count rather
    /// than split per-pass because the user-facing story is "tokens
    /// generated locally", not "tokens per pass". Always zero when no
    /// LLM engine is selected.
    public var llmTokensIn: Int = 0
    public var llmTokensOut: Int = 0

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

    /// Speaking rate across every dictation, in words per minute, measured
    /// on the words actually *delivered* rather than the raw transcript —
    /// that's the number that describes what the user got out of the app.
    ///
    /// nil until there's enough audio to be meaningful. A handful of seconds
    /// divides into a wild figure and reads as a bug.
    public var wordsPerMinute: Int? {
        guard dictationSeconds >= 30, dictationWordsOutTimed > 0 else { return nil }
        return Int((Double(dictationWordsOutTimed) / (dictationSeconds / 60)).rounded())
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
            dictationSeconds: lhs.dictationSeconds + rhs.dictationSeconds,
            dictationWordsOutTimed: lhs.dictationWordsOutTimed + rhs.dictationWordsOutTimed,
            assistantWordsIn: lhs.assistantWordsIn + rhs.assistantWordsIn,
            assistantWordsOut: lhs.assistantWordsOut + rhs.assistantWordsOut,
            llmTokensIn: lhs.llmTokensIn + rhs.llmTokensIn,
            llmTokensOut: lhs.llmTokensOut + rhs.llmTokensOut
        )
    }
}

extension UsageStats: Codable {
    private enum CodingKeys: String, CodingKey {
        case dictationCount, assistantCount
        case dictationWordsIn, dictationWordsOut
        case dictationSeconds, dictationWordsOutTimed
        case assistantWordsIn, assistantWordsOut
        case llmTokensIn, llmTokensOut
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
        if let timed = try c.decodeIfPresent(Int.self, forKey: .dictationWordsOutTimed) {
            dictationWordsOutTimed = timed
            dictationSeconds = try c.decodeIfPresent(Double.self, forKey: .dictationSeconds) ?? 0
        } else {
            // A file written before the paired counter existed. Any seconds on
            // disk have no matching word count, so keeping them would under-
            // state the rate for as long as they sat in the denominator —
            // the mirror image of the bug this pairing fixes. Both sides start
            // at zero together; a few minutes of orphaned audio is a cheap
            // price for a figure that's honest from the first reading.
            dictationWordsOutTimed = 0
            dictationSeconds = 0
        }
        llmTokensIn = try c.decodeIfPresent(Int.self, forKey: .llmTokensIn) ?? 0
        llmTokensOut = try c.decodeIfPresent(Int.self, forKey: .llmTokensOut) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dictationCount, forKey: .dictationCount)
        try c.encode(assistantCount, forKey: .assistantCount)
        try c.encode(dictationWordsIn, forKey: .dictationWordsIn)
        try c.encode(dictationWordsOut, forKey: .dictationWordsOut)
        try c.encode(dictationSeconds, forKey: .dictationSeconds)
        try c.encode(dictationWordsOutTimed, forKey: .dictationWordsOutTimed)
        try c.encode(assistantWordsIn, forKey: .assistantWordsIn)
        try c.encode(assistantWordsOut, forKey: .assistantWordsOut)
        try c.encode(llmTokensIn, forKey: .llmTokensIn)
        try c.encode(llmTokensOut, forKey: .llmTokensOut)
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
    /// Dictations per local calendar day, keyed `yyyy-MM-dd`. Kept per device
    /// for the same reason every other counter is: two Macs writing the file
    /// must not be able to lose each other's days.
    ///
    /// Local dates, deliberately. A streak is a human fact about the days
    /// somebody showed up, so it has to agree with the calendar on their wall
    /// rather than with UTC.
    var days: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case deviceName, platform, stats, firstSeen, lastUpdated, days
    }

    init(deviceName: String, platform: String, stats: UsageStats,
         firstSeen: Date, lastUpdated: Date, days: [String: Int] = [:]) {
        self.deviceName = deviceName
        self.platform = platform
        self.stats = stats
        self.firstSeen = firstSeen
        self.lastUpdated = lastUpdated
        self.days = days
    }

    /// Tolerant of records written before `days` existed — they simply have
    /// no history, and the streak starts from the next dictation.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Mac"
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "macOS"
        stats = try c.decodeIfPresent(UsageStats.self, forKey: .stats) ?? .zero
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
        days = try c.decodeIfPresent([String: Int].self, forKey: .days) ?? [:]
    }
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

    /// Just this device's contribution to the shared file. Same shape
    /// as `totals` so the UI can render side-by-side comparisons
    /// (e.g. "this Mac vs. all my Macs" on the LLM token card) when
    /// `deviceCount > 1`. Zero when this device has never recorded
    /// anything — the row simply hides in that case.
    public private(set) var thisDeviceStats: UsageStats = .zero

    /// How many distinct devices have at least one record in the
    /// shared file. UI uses this to decide whether the per-device
    /// breakdown is worth surfacing — a one-device install has no
    /// "all devices" angle to compare against, so the comparison
    /// layout is suppressed.
    public private(set) var deviceCount: Int = 0

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

    /// Add LLM token usage to this device's running totals. Called by
    /// the LLM services after every completed generate / respond call.
    /// Tokens land in a combined bucket — across format / grammar /
    /// structure / assistant passes — because the user story is
    /// "tokens generated locally", not per-pass accounting. Zero or
    /// negative inputs are coerced to zero; we don't want a failed
    /// detached-task accounting hop to drive the total backwards.
    public func recordLLMTokens(in tokensIn: Int, out tokensOut: Int) {
        ensureLoaded()
        guard tokensIn > 0 || tokensOut > 0 else { return }
        var record = records[deviceID] ?? freshRecord()
        record.stats.llmTokensIn += max(0, tokensIn)
        record.stats.llmTokensOut += max(0, tokensOut)
        record.lastUpdated = Date()
        records[deviceID] = record
        recomputeTotals()
        persist()
    }

    /// Increment this device's counters by the supplied amounts. Loads
    /// on first call. Failure to persist is logged but never thrown —
    /// stats are nice-to-have, not load-bearing for the dictation path.
    public func record(mode: UsageStatsMode, wordsIn: Int, wordsOut: Int, spokenSeconds: Double = 0) {
        ensureLoaded()
        var record = records[deviceID] ?? freshRecord()
        let safeIn = max(0, wordsIn)
        let safeOut = max(0, wordsOut)
        let key = Self.dayKey(for: Date())
        record.days[key, default: 0] += 1
        Self.trimDays(&record.days)
        switch mode {
        case .dictation:
            record.stats.dictationCount += 1
            record.stats.dictationWordsIn += safeIn
            record.stats.dictationWordsOut += safeOut
            // Clamped: a clock jump or a wedged recorder must not be able to
            // drive the words-per-minute denominator to nonsense.
            if spokenSeconds > 0, spokenSeconds < 3600 {
                record.stats.dictationSeconds += spokenSeconds
                // Always in the same breath as the seconds — that pairing is
                // the entire point of this field.
                record.stats.dictationWordsOutTimed += safeOut
            }
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
            if let stored = AppDefaults.shared.string(forKey: Self.deviceIDKey), !stored.isEmpty {
                deviceID = stored
            } else {
                let fresh = UUID().uuidString
                AppDefaults.shared.set(fresh, forKey: Self.deviceIDKey)
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
        thisDeviceStats = records[deviceID]?.stats ?? .zero
        deviceCount = records.count

        // Days are summed across devices, not maxed: dictating on the laptop
        // and the desktop on the same day is two dictations, and for the
        // streak all that matters is that the day is non-zero either way.
        var merged: [String: Int] = [:]
        for record in records.values {
            for (key, count) in record.days {
                merged[key, default: 0] += count
            }
        }
        dailyCounts = merged
        let streaks = Self.streaks(in: Set(merged.keys))
        currentStreak = streaks.current
        bestStreak = streaks.best
    }

    // MARK: - Streaks

    /// Dictations per local calendar day, summed across every device.
    public private(set) var dailyCounts: [String: Int] = [:]
    /// Consecutive days up to today (or yesterday — a streak isn't broken
    /// until a day has fully passed without one, otherwise every streak would
    /// read as zero until the first dictation each morning).
    public private(set) var currentStreak: Int = 0
    /// Longest run of consecutive days ever recorded.
    public private(set) var bestStreak: Int = 0

    /// Counts for the last `count` days ending today, oldest first — the heat
    /// strip's data. Days with no activity come back as zero rather than being
    /// absent, so the caller can render a fixed-width row.
    public func recentDays(_ count: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, dailyCounts[Self.dayKey(for: date)] ?? 0)
        }
    }

    /// Current and best run lengths over a set of `yyyy-MM-dd` keys.
    static func streaks(in days: Set<String>) -> (current: Int, best: Int) {
        guard !days.isEmpty else { return (0, 0) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        func run(endingAt start: Date) -> Int {
            var length = 0
            var cursor = start
            while days.contains(dayKey(for: cursor)) {
                length += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
            return length
        }

        // Today not yet used doesn't end a streak — the day isn't over.
        var current = run(endingAt: today)
        if current == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            current = run(endingAt: yesterday)
        }

        // Best: walk every recorded day and measure the run that ends there.
        // Only days whose successor is absent can end a run, which keeps this
        // linear in practice rather than quadratic.
        var best = current
        for key in days {
            guard let date = dayFormatter.date(from: key) else { continue }
            if let next = calendar.date(byAdding: .day, value: 1, to: date),
               days.contains(dayKey(for: next)) {
                continue
            }
            best = max(best, run(endingAt: date))
        }
        return (current, best)
    }

    /// Keep a rolling window of days. Two years is far more than any UI shows
    /// and keeps the file from growing without bound on a long-lived install.
    private static func trimDays(_ days: inout [String: Int]) {
        let limit = 730
        guard days.count > limit else { return }
        for key in days.keys.sorted().prefix(days.count - limit) {
            days.removeValue(forKey: key)
        }
    }

    static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// Local time zone on purpose — see `UsageStatsDeviceRecord.days`. Fixed
    /// POSIX locale so the key format can't shift with the user's region.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
        return AppSupportPaths.dictator
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
            dictationSeconds: max(existing.stats.dictationSeconds, incoming.stats.dictationSeconds),
            dictationWordsOutTimed: max(existing.stats.dictationWordsOutTimed, incoming.stats.dictationWordsOutTimed),
            assistantWordsIn: max(existing.stats.assistantWordsIn, incoming.stats.assistantWordsIn),
            assistantWordsOut: max(existing.stats.assistantWordsOut, incoming.stats.assistantWordsOut),
            llmTokensIn: max(existing.stats.llmTokensIn, incoming.stats.llmTokensIn),
            llmTokensOut: max(existing.stats.llmTokensOut, incoming.stats.llmTokensOut)
        )
        var days = existing.days
        for (key, count) in incoming.days {
            days[key] = max(days[key] ?? 0, count)
        }
        Self.trimDays(&days)
        return UsageStatsDeviceRecord(
            deviceName: incoming.deviceName,
            platform: incoming.platform,
            stats: stats,
            firstSeen: min(existing.firstSeen, incoming.firstSeen),
            lastUpdated: max(existing.lastUpdated, incoming.lastUpdated),
            days: days
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
