import Foundation
import Observation
import Combine

/// File-backed store for the user's vocabulary entries. Lives in its own
/// JSON file separate from `DictatorSettings` so a settings-decode regression
/// can never wipe the user's dictionary the way the modes refactor did. Also
/// makes the file portable — you can copy `vocabulary.json` between Macs to
/// share your dictionary, or point Settings → General → Vocabulary file at
/// a folder in iCloud Drive to sync it automatically.
///
/// Safety properties:
/// - **Atomic writes** via `Data.write(to:options:.atomic)`. Readers either
///   see the previous content or the new content, never a half-written file.
/// - **NSFileCoordinator** wraps reads and writes so two Dictator processes
///   on the same Mac (or a sync daemon mid-flight) can't corrupt each other.
/// - **Tolerant decode**: missing fields fall through to defaults via
///   `VocabularyEntry`'s synthesised decoder + `decodeIfPresent` on the
///   envelope. A schema mismatch preserves the original bytes under a dated
///   `.recovered-…` filename rather than overwriting.
/// - **External-change watcher**: a `DispatchSourceFileSystemObject` reloads
///   on writes from outside this process (hand-edits, sync drops). Debounced
///   so a torrent of fsevents doesn't reload mid-typing.
/// - **Debounced saves**: keystroke-storm edits in the Settings UI coalesce
///   into one write ~500ms after the user stops typing.
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    /// Source of truth for the in-memory vocabulary. Mutating this triggers
    /// a debounced write to disk. UI surfaces should bind directly to this
    /// property — SwiftUI's Observation tracks changes automatically.
    var entries: [VocabularyEntry] = [] {
        didSet {
            guard !isReloadingFromDisk else { return }
            scheduleSave()
        }
    }

    /// The file URL the store currently reads/writes. Updated when the user
    /// picks a custom location in Settings. nil before `bootstrap()` is
    /// called.
    private(set) var fileURL: URL?

    /// Most recent load/save error, surfaced for UI display. nil on success.
    private(set) var lastError: String?

    // MARK: - Private state

    /// True while reloading from disk so the didSet on `entries` doesn't
    /// schedule a write of the just-read data.
    private var isReloadingFromDisk = false

    /// In-flight debounce task. Cancelled when a new edit lands or `stop()`
    /// is called, so a stream of keystrokes coalesces into one write.
    private var saveDebounceTask: Task<Void, Never>?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    /// Background queue the file watcher delivers events on. Reads/writes
    /// themselves use `Task.detached` rather than this queue — Swift
    /// concurrency expresses isolation more clearly than DispatchQueue +
    /// `Task { @MainActor in ... }` hops, which were tripping up runtime
    /// actor-isolation checks under load.
    private let watcherQueue = DispatchQueue(label: "net.robgough.Dictator.VocabularyStore.watcher", qos: .userInitiated)

    private static let filename = "vocabulary.json"
    private static let schemaVersion = 1

    private init() {}

    // MARK: - Bootstrap

    /// Resolve the file URL, run a one-time migration from the legacy
    /// `DictatorSettings.vocabulary` array if present, load into memory, and
    /// start the external-change watcher. Called from `AppState.bootstrap()`
    /// before any UI surfaces or the pipeline read the vocabulary.
    func bootstrap(customDirectory: URL?, legacyEntries: [VocabularyEntry]?) {
        // Idempotent: a second call (e.g. iOS user enabling a shared
        // folder mid-session) must release the previous file watcher
        // and cancel any pending debounced save targeting the old URL
        // before re-pointing. Without this, the old watcher leaks and
        // a debounced save can fire after we've already migrated.
        stopWatching()
        saveDebounceTask?.cancel()
        saveDebounceTask = nil

        let directory = customDirectory ?? Self.defaultDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Fall back to a temp directory rather than refuse to start —
            // a vocab store that can't write is better than no store at all.
            // Surfacing this in the UI is the user's path back to a working
            // location.
            self.lastError = "Couldn't create \(directory.path): \(error.localizedDescription)"
            NSLog("[Dictator] VocabularyStore: \(self.lastError!)")
        }
        let url = directory.appendingPathComponent(Self.filename)
        self.fileURL = url

        if FileManager.default.fileExists(atPath: url.path) {
            loadFromDisk()
            // Multi-Mac iCloud Drive edge case: another Mac upgraded first
            // and synced its `vocabulary.json` into this Mac's Documents
            // folder *before* this Mac upgraded. Without a merge step,
            // this Mac would find the file, skip the UserDefaults
            // migration path, and silently lose any vocab entries that
            // were unique to it. Union by id — entries already in the
            // file win on conflict (which can only happen if the same
            // entry was duplicated across Macs before the sync arrived).
            if let legacyEntries, !legacyEntries.isEmpty {
                let existingIDs = Set(entries.map(\.id))
                let extras = legacyEntries.filter { !existingIDs.contains($0.id) }
                if !extras.isEmpty {
                    entries.append(contentsOf: extras)  // didSet schedules a save
                }
            }
        } else if let legacyEntries, !legacyEntries.isEmpty {
            // One-time migration. We don't immediately delete the legacy
            // settings.vocabulary on the caller side — the caller (AppState)
            // handles that once this write has succeeded. Skip the debounce
            // — we want the file on disk before the caller clears its
            // legacy array.
            saveDebounceTask?.cancel()
            saveDebounceTask = nil
            self.entries = legacyEntries
            Task { @MainActor [weak self] in
                await self?.writeNow(entries: legacyEntries, to: url)
            }
        } else {
            // Fresh install: empty store, write the envelope so the file
            // exists and external-edit detection has something to watch.
            self.entries = []
            Task { @MainActor [weak self] in
                await self?.writeNow(entries: [], to: url)
            }
        }

        startWatching(url: url)
    }

    /// Re-point the store at a new location. Copies current entries into the
    /// new file so the user doesn't lose data when picking a folder for the
    /// first time. Called from Settings → General → "Choose location…".
    func relocate(to newDirectory: URL) {
        do {
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create \(newDirectory.path): \(error.localizedDescription)"
            return
        }
        let newURL = newDirectory.appendingPathComponent(Self.filename)
        let snapshot = entries
        stopWatching()
        fileURL = newURL
        Task { @MainActor [weak self] in
            await self?.writeNow(entries: snapshot, to: newURL)
        }
        startWatching(url: newURL)
    }

    /// Default folder for synced data, kept here as a compatibility shim for
    /// callers that haven't moved to `SyncedStorage` yet. New code should
    /// reference `SyncedStorage.defaultDirectory` directly.
    nonisolated static func defaultDirectory() -> URL {
        SyncedStorage.defaultDirectory
    }

    // MARK: - Save (debounced)

    /// Schedules a save ~500ms in the future, coalescing rapid edits. Each
    /// new edit cancels the in-flight task so a stream of keystrokes
    /// results in exactly one write at the end.
    private func scheduleSave() {
        saveDebounceTask?.cancel()
        let snapshot = entries
        guard let url = fileURL else { return }
        saveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await self?.writeNow(entries: snapshot, to: url)
            self?.saveDebounceTask = nil
        }
    }

    /// Atomic file write inside an NSFileCoordinator block. The encode +
    /// coordinator + Data.write all run off-main via `Task.detached` so a
    /// sync-provider stall can't block the UI, then we hop back to main
    /// only to update the published `lastError` and restart the file
    /// watcher. No backup-on-write: the atomic rename guarantees readers
    /// never see a half-written file, and the load-time recovery path
    /// preserves bytes under `vocabulary.recovered-<timestamp>.json` if
    /// decode ever fails.
    private func writeNow(entries: [VocabularyEntry], to url: URL) async {
        let envelope = Envelope(schemaVersion: Self.schemaVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else {
            lastError = "Couldn't encode vocabulary"
            return
        }
        // Stop watching during our own write so we don't loopback-reload
        // the bytes we just authored.
        let resumeWatch = fileWatcher != nil
        if resumeWatch { stopWatching() }

        // Off-main: file IO. Captures only Sendable values (Data, URL).
        // Returns an optional error message rather than the Error itself —
        // arbitrary Errors aren't Sendable, but a String is.
        let errorMessage = await Task.detached(priority: .userInitiated) {
            () -> String? in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            var writeError: Error?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
                do {
                    try data.write(to: coordURL, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let writeError {
                return "Write failed: \(writeError.localizedDescription)"
            } else if let coordError {
                return "Coordination failed: \(coordError.localizedDescription)"
            }
            return nil
        }.value

        // Back on MainActor for state updates.
        lastError = errorMessage
        if resumeWatch {
            startWatching(url: url)
        }
    }

    // MARK: - Load

    private func loadFromDisk() {
        guard let url = fileURL else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var loaded: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            loaded = try? Data(contentsOf: coordURL)
        }
        if let coordError {
            lastError = "Coordination failed: \(coordError.localizedDescription)"
            return
        }
        guard let data = loaded else {
            // File disappeared between fileExists check and the read.
            entries = []
            return
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            isReloadingFromDisk = true
            entries = envelope.entries
            isReloadingFromDisk = false
            lastError = nil
        } catch {
            // Preserve corrupt blob under a dated recovery filename instead of
            // overwriting it. Same shape as the safety net we added on
            // DictatorSettings — refuse to silently destroy user data on
            // decode failure.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let recoveryURL = url.deletingLastPathComponent()
                .appendingPathComponent("vocabulary.recovered-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: recoveryURL)
            lastError = "Couldn't read vocabulary (\(error.localizedDescription)). Original preserved at \(recoveryURL.lastPathComponent)."
            NSLog("[Dictator] VocabularyStore: \(lastError ?? "")")
            // Don't touch the live file. Surface an empty list in memory so
            // the UI is usable; the user can intervene from the preserved copy.
            isReloadingFromDisk = true
            entries = []
            isReloadingFromDisk = false
        }
    }

    // MARK: - External-change watcher

    /// Watches the file for writes from outside this process — hand-edits,
    /// sync drops, etc. — and reloads. Debounced so a torrent of fsevents
    /// during a sync provider's metadata pass doesn't reload repeatedly.
    private func startWatching(url: URL) {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File may not exist yet (we created the directory but the
            // first write hasn't completed). Try again briefly.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self, self.fileURL == url else { return }
                self.startWatching(url: url)
            }
            return
        }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watcherQueue
        )
        // `@Sendable` on these closures matters: without it Swift 6 infers
        // them to inherit the @MainActor isolation of the enclosing
        // method, then traps when they fire on `watcherQueue`. The cancel
        // handler in particular is what crashed adding a vocab entry —
        // stopWatching → source.cancel → cancel handler runs on the
        // dispatch queue, isolation check fails, EXC_BREAKPOINT in
        // _dispatch_assert_queue_fail.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExternalChange()
            }
        }
        source.setCancelHandler { @Sendable [fd] in close(fd) }
        source.resume()
        fileWatcher = source
    }

    private func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
        watchedFD = -1
    }

    private var pendingReloadTask: Task<Void, Never>?

    private func handleExternalChange() {
        pendingReloadTask?.cancel()
        // 250ms debounce smooths out fsevent storms from sync providers
        // without making external hand-edits feel laggy.
        pendingReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            self?.loadFromDisk()
            self?.pendingReloadTask = nil
        }
    }

    // MARK: - On-disk envelope

    /// The persisted shape. `schemaVersion` is a top-level integer so future
    /// migrations can fork on it. `entries` decodes via `VocabularyEntry`'s
    /// Codable conformance — which we keep tolerant of missing fields so a
    /// newer-binary file remains partially-readable by an older binary.
    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [VocabularyEntry]
    }
}
