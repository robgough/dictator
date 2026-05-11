import Foundation
import Observation

enum ModelDownloadState: Equatable, Sendable {
    case unknown
    case notDownloaded
    /// A previous download was interrupted but bytes are still on disk. Hub's
    /// Downloader honours `Range:` requests against `<file>.<etag>.incomplete`,
    /// so clicking Resume picks up where it left off rather than starting over.
    /// The associated value is the fraction of expected size already downloaded
    /// (0...1) for display only — Hub computes the real resume offset itself.
    case partial(Double)
    case downloading(Double)
    case ready
    case failed(String)
}

@MainActor
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var whisperStates: [String: ModelDownloadState] = [:]
    private(set) var llmStates: [String: ModelDownloadState] = [:]

    // Per-model in-flight download Tasks. Tracked so the user can cancel a
    // download from the Settings UI; also dedupes accidental double-taps on
    // the Download button.
    private var whisperTasks: [String: Task<Void, Never>] = [:]
    private var llmTasks: [String: Task<Void, Never>] = [:]

    private init() {
        refreshCachedStates()
    }

    func refreshCachedStates() {
        for m in ModelCatalog.whisperModels {
            whisperStates[m.id] = diskState(forWhisper: m.id, expectedMB: m.approxSizeMB)
        }
        for m in ModelCatalog.llmModels {
            llmStates[m.id] = diskState(forLLM: m.id, expectedMB: m.approxSizeMB)
        }
    }

    // MARK: - Disk-state inspection
    //
    // Hub's Downloader writes to `<filename>.<etag>.incomplete` in the per-repo
    // metadata cache (`<repoDir>/.cache/huggingface/download/...`), then moves
    // the file to its final location and writes a `<filename>.metadata` marker.
    // The presence of any `.incomplete` file under that metadata subtree is
    // the canonical signal that a download was interrupted and the bytes
    // already on disk can be resumed via Hub's built-in `Range:` retry.

    private func diskState(forWhisper id: String, expectedMB: Int) -> ModelDownloadState {
        // <root>/models/argmaxinc/whisperkit-coreml/<variant>/             ← snapshot
        // <root>/models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/<variant>/ ← metadata
        let snapshot = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
        let metadata = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(id)", isDirectory: true)
        return diskState(snapshot: snapshot, metadata: metadata, expectedMB: expectedMB,
                         snapshotReadyIf: { contents in contents.contains { $0.hasSuffix(".mlmodelc") } })
    }

    private func diskState(forLLM id: String, expectedMB: Int) -> ModelDownloadState {
        // <root>/models/<repoId>/                                ← snapshot
        // <root>/models/<repoId>/.cache/huggingface/download/    ← metadata (lives inside snapshot)
        let snapshot = ModelStorage.llmRoot()
            .appendingPathComponent("models/\(id)", isDirectory: true)
        let metadata = snapshot
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        return diskState(snapshot: snapshot, metadata: metadata, expectedMB: expectedMB,
                         snapshotReadyIf: { contents in contents.contains { !$0.hasPrefix(".") } })
    }

    /// Common inspection. If any `.incomplete` files sit under `metadata`,
    /// the repo is `.partial`. Otherwise the `snapshotReadyIf` predicate
    /// decides between `.ready` and `.notDownloaded` from the snapshot's
    /// contents.
    private func diskState(snapshot: URL, metadata: URL, expectedMB: Int,
                           snapshotReadyIf isReady: ([String]) -> Bool) -> ModelDownloadState {
        let fm = FileManager.default
        let incompleteBytes = totalIncompleteBytes(under: metadata)
        if incompleteBytes > 0 {
            // Use the catalog's approxSizeMB as the denominator — the only
            // estimate available without re-contacting the server. Good
            // enough for a "Resume — 42%" UI hint; Hub computes the real
            // resume offset from the actual .incomplete file size itself.
            let expectedBytes = Double(expectedMB) * 1_000_000
            let fraction = min(0.99, max(0.01, Double(incompleteBytes) / expectedBytes))
            return .partial(fraction)
        }
        guard fm.fileExists(atPath: snapshot.path) else { return .notDownloaded }
        let contents = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
        return isReady(contents) ? .ready : .notDownloaded
    }

    /// Sum the byte sizes of every `*.incomplete` file under `dir`. Returns 0
    /// when the dir doesn't exist or contains no in-flight downloads.
    private func totalIncompleteBytes(under dir: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return 0 }
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Download triggers (call into the services so it warms the cache too)

    /// Fire-and-forget download. Stores the Task so the user can cancel from
    /// Settings. No-ops if a download for this model is already in flight.
    func downloadWhisper(_ id: String, using service: TranscriptionService) {
        guard whisperTasks[id] == nil else { return }
        whisperStates[id] = .downloading(0)
        whisperTasks[id] = Task { [weak self] in
            do {
                try await service.download(modelID: id) { [weak self] progress in
                    // Don't overwrite a terminal state if cancellation already
                    // flipped us back to .notDownloaded after a late progress
                    // tick from the underlying HubApi callback.
                    guard let self else { return }
                    if case .downloading = self.whisperStates[id] {
                        self.whisperStates[id] = .downloading(progress)
                    }
                }
                guard let self else { return }
                // Only transition to .ready if we weren't cancelled.
                if Task.isCancelled {
                    self.whisperStates[id] = .notDownloaded
                } else {
                    self.whisperStates[id] = .ready
                }
            } catch is CancellationError {
                self?.whisperStates[id] = .notDownloaded
            } catch {
                if Task.isCancelled {
                    self?.whisperStates[id] = .notDownloaded
                } else {
                    self?.whisperStates[id] = .failed(error.localizedDescription)
                }
            }
            self?.whisperTasks[id] = nil
        }
    }

    /// Fire-and-forget download. Stores the Task so the user can cancel from
    /// Settings. No-ops if a download for this model is already in flight.
    func downloadLLM(_ id: String, using service: LLMService) {
        guard llmTasks[id] == nil else { return }
        llmStates[id] = .downloading(0)
        llmTasks[id] = Task { [weak self] in
            do {
                try await service.ensureLoaded(modelID: id) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if case .downloading = self.llmStates[id] {
                            self.llmStates[id] = .downloading(progress)
                        }
                    }
                }
                guard let self else { return }
                if Task.isCancelled {
                    self.llmStates[id] = .notDownloaded
                } else {
                    self.llmStates[id] = .ready
                }
            } catch is CancellationError {
                self?.llmStates[id] = .notDownloaded
            } catch {
                if Task.isCancelled {
                    self?.llmStates[id] = .notDownloaded
                } else {
                    self?.llmStates[id] = .failed(error.localizedDescription)
                }
            }
            self?.llmTasks[id] = nil
        }
    }

    /// Cancel an in-flight Whisper download. The underlying HubApi network
    /// activity may take a moment to wind down depending on what file it's
    /// partway through. We immediately recompute the on-disk state so the row
    /// reflects whatever bytes were captured ("Resume — 42%") rather than
    /// pretending nothing happened.
    func cancelWhisperDownload(_ id: String) {
        whisperTasks[id]?.cancel()
        whisperTasks[id] = nil
        // Recompute from disk so any `.incomplete` files surface as .partial.
        if let model = ModelCatalog.whisper(id: id) {
            whisperStates[id] = diskState(forWhisper: id, expectedMB: model.approxSizeMB)
        } else {
            whisperStates[id] = .notDownloaded
        }
    }

    func cancelLLMDownload(_ id: String) {
        llmTasks[id]?.cancel()
        llmTasks[id] = nil
        if let model = ModelCatalog.llm(id: id) {
            llmStates[id] = diskState(forLLM: id, expectedMB: model.approxSizeMB)
        } else {
            llmStates[id] = .notDownloaded
        }
    }

    // MARK: - Deletion

    /// Unload (if loaded) and remove a Whisper model's on-disk files. Returns
    /// whether the snapshot directory was found and removed. Also wipes the
    /// per-variant entry in Hub's metadata cache so any stale `.incomplete`
    /// or `.metadata` markers don't survive and confuse the next disk-state
    /// check (would otherwise look like a partial download lingering).
    @discardableResult
    func removeWhisper(_ id: String, using service: TranscriptionService) -> Bool {
        service.unload(modelID: id)
        let snapshot = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
        let metadata = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(id)", isDirectory: true)
        let removed = removeDirectory(at: snapshot)
        _ = removeDirectory(at: metadata)
        whisperStates[id] = .notDownloaded
        return removed
    }

    /// Unload (if loaded) and remove an LLM model's on-disk files.
    @discardableResult
    func removeLLM(_ id: String, using service: LLMService) -> Bool {
        service.unload(modelID: id)
        let dir = ModelStorage.llmRoot()
            .appendingPathComponent("models/\(id)", isDirectory: true)
        let removed = removeDirectory(at: dir)
        llmStates[id] = .notDownloaded
        return removed
    }

    private func removeDirectory(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
