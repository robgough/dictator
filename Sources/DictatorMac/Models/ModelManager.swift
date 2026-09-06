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
    /// Click registered, but no bytes received yet. Hub's `snapshot` lists the
    /// repo (one HTTP call) then fetches per-file metadata (N more) before any
    /// progress tick fires, so the bar would otherwise sit at "0%" for several
    /// seconds on a slow connection and look stalled. Distinguishing this from
    /// `.downloading(0)` lets the UI show "Fetching metadata…" until the first
    /// real progress callback arrives and we know bytes are flowing.
    case preparingDownload
    case downloading(Double)
    case ready
    case failed(String)
}

@MainActor
@Observable
final class ModelManager {
    static let shared = ModelManager()

    private(set) var whisperStates: [String: ModelDownloadState] = [:]
    private(set) var parakeetStates: [String: ModelDownloadState] = [:]
    private(set) var llmStates: [String: ModelDownloadState] = [:]
    private(set) var diarizationStates: [String: ModelDownloadState] = [:]

    /// IDs currently mid-verify. Drives a small inline spinner next to the
    /// Verify button — purely for UX, not used for any logic.
    private(set) var verifyingWhisper: Set<String> = []
    private(set) var verifyingParakeet: Set<String> = []
    private(set) var verifyingLLM: Set<String> = []
    private(set) var verifyingDiarization: Set<String> = []

    // Per-model in-flight download Tasks. Tracked so the user can cancel a
    // download from the Settings UI; also dedupes accidental double-taps on
    // the Download button.
    private var whisperTasks: [String: Task<Void, Never>] = [:]
    private var parakeetTasks: [String: Task<Void, Never>] = [:]
    private var llmTasks: [String: Task<Void, Never>] = [:]
    private var diarizationTasks: [String: Task<Void, Never>] = [:]

    private init() {
        refreshCachedStates()
    }

    func refreshCachedStates() {
        for m in ModelCatalog.whisperModels {
            whisperStates[m.id] = diskState(forWhisper: m.id, expectedMB: m.approxSizeMB)
        }
        for m in ModelCatalog.parakeetModels {
            parakeetStates[m.id] = diskState(forParakeet: m.id)
        }
        for m in ModelCatalog.llmModels {
            llmStates[m.id] = diskState(forLLM: m.id, expectedMB: m.approxSizeMB)
        }
        for m in ModelCatalog.diarizationModels {
            diarizationStates[m.id] = diskState(forDiarization: m.id)
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
        let snapshot = ModelStorage.whisperModelDirectory(for: id)
        let metadata = ModelStorage.whisperDownloadMetadataDirectory(for: id)
        return diskState(snapshot: snapshot, metadata: metadata, expectedMB: expectedMB,
                         snapshotReadyIf: { contents in contents.contains { $0.hasSuffix(".mlmodelc") } })
    }

    /// Parakeet disk-state probe. FluidAudio writes each model file atomically
    /// (write to temp, rename to final) under `<parakeetRoot>/<id>/`, with no
    /// per-file `.incomplete` markers. So unlike Hub-backed downloads we can't
    /// distinguish `.partial` from `.notDownloaded` — a half-finished download
    /// shows as "missing files" and FluidAudio will simply refetch them on
    /// next run. The trade-off is acceptable: the user only sees `.ready` or
    /// `.notDownloaded`, never a stale "Resume — 42%" hint that misleads.
    private func diskState(forParakeet id: String) -> ModelDownloadState {
        ParakeetService.modelsExist(id: id) ? .ready : .notDownloaded
    }

    /// Diarization bundle is atomic the same way FluidAudio's Parakeet
    /// snapshot is — no per-file `.incomplete` markers — so we only ever
    /// flip between `.ready` and `.notDownloaded`.
    private func diskState(forDiarization id: String) -> ModelDownloadState {
        DiarizerService.modelsExist(id: id) ? .ready : .notDownloaded
    }

    private func diskState(forLLM id: String, expectedMB: Int) -> ModelDownloadState {
        // <root>/models/<repoId>/                                ← snapshot
        // <root>/models/<repoId>/.cache/huggingface/download/    ← metadata (lives inside snapshot)
        let snapshot = ModelStorage.llmModelDirectory(for: id)
        let metadata = ModelStorage.llmDownloadMetadataDirectory(for: id)
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
        whisperStates[id] = .preparingDownload
        whisperTasks[id] = Task { [weak self] in
            do {
                try await service.download(modelID: id) { [weak self] progress in
                    // Don't overwrite a terminal state if cancellation already
                    // flipped us back to .notDownloaded after a late progress
                    // tick from the underlying HubApi callback. Also accept
                    // the pre-network `.preparingDownload` state — the first
                    // progress tick is what flips us out of it.
                    guard let self else { return }
                    switch self.whisperStates[id] {
                    case .preparingDownload, .downloading:
                        self.whisperStates[id] = .downloading(progress)
                    default:
                        break
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

    /// Fire-and-forget Parakeet download. Mirrors the Whisper variant.
    func downloadParakeet(_ id: String, using service: ParakeetService) {
        guard parakeetTasks[id] == nil else { return }
        parakeetStates[id] = .preparingDownload
        parakeetTasks[id] = Task { [weak self] in
            do {
                try await service.download(modelID: id) { [weak self] progress in
                    guard let self else { return }
                    switch self.parakeetStates[id] {
                    case .preparingDownload, .downloading:
                        self.parakeetStates[id] = .downloading(progress)
                    default:
                        break
                    }
                }
                guard let self else { return }
                if Task.isCancelled {
                    // FluidAudio doesn't leave resumable partials behind — recompute
                    // the on-disk state to either .ready (download finished before
                    // cancel reached it) or .notDownloaded.
                    self.parakeetStates[id] = self.diskState(forParakeet: id)
                } else {
                    self.parakeetStates[id] = .ready
                }
            } catch is CancellationError {
                self?.parakeetStates[id] = self?.diskState(forParakeet: id) ?? .notDownloaded
            } catch {
                if Task.isCancelled {
                    self?.parakeetStates[id] = self?.diskState(forParakeet: id) ?? .notDownloaded
                } else {
                    self?.parakeetStates[id] = .failed(error.localizedDescription)
                }
            }
            self?.parakeetTasks[id] = nil
        }
    }

    /// Fire-and-forget diarization download. Mirrors the Parakeet variant.
    func downloadDiarization(_ id: String, using service: DiarizerService) {
        guard diarizationTasks[id] == nil else { return }
        diarizationStates[id] = .preparingDownload
        diarizationTasks[id] = Task { [weak self] in
            do {
                try await service.download(modelID: id) { [weak self] progress in
                    guard let self else { return }
                    switch self.diarizationStates[id] {
                    case .preparingDownload, .downloading:
                        self.diarizationStates[id] = .downloading(progress)
                    default:
                        break
                    }
                }
                guard let self else { return }
                if Task.isCancelled {
                    self.diarizationStates[id] = self.diskState(forDiarization: id)
                } else {
                    self.diarizationStates[id] = .ready
                }
            } catch is CancellationError {
                self?.diarizationStates[id] = self?.diskState(forDiarization: id) ?? .notDownloaded
            } catch {
                if Task.isCancelled {
                    self?.diarizationStates[id] = self?.diskState(forDiarization: id) ?? .notDownloaded
                } else {
                    self?.diarizationStates[id] = .failed(error.localizedDescription)
                }
            }
            self?.diarizationTasks[id] = nil
        }
    }

    /// Fire-and-forget download. Stores the Task so the user can cancel from
    /// Settings. No-ops if a download for this model is already in flight.
    /// Downloads files only — the heavy compile + RAM-resident load happens
    /// lazily the first time the pipeline actually needs the model. Previously
    /// this called `ensureLoaded`, which silently kept the model loaded in
    /// memory after "Download" finished and left the UI frozen at 100% during
    /// the multi-second compile tail.
    func downloadLLM(_ id: String, using service: MLXLLMService) {
        guard llmTasks[id] == nil else { return }
        llmStates[id] = .preparingDownload
        llmTasks[id] = Task { [weak self] in
            do {
                try await service.download(modelID: id) { [weak self] progress in
                    guard let self else { return }
                    switch self.llmStates[id] {
                    case .preparingDownload, .downloading:
                        self.llmStates[id] = .downloading(progress)
                    default:
                        break
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

    func cancelParakeetDownload(_ id: String) {
        parakeetTasks[id]?.cancel()
        parakeetTasks[id] = nil
        parakeetStates[id] = diskState(forParakeet: id)
    }

    func cancelDiarizationDownload(_ id: String) {
        diarizationTasks[id]?.cancel()
        diarizationTasks[id] = nil
        diarizationStates[id] = diskState(forDiarization: id)
    }

    // MARK: - Verify (load into memory + report failure to disk state)

    /// Attempt to load the model into memory to confirm the on-disk files are
    /// actually usable. Catches load failures — most often "corrupt download
    /// on a flaky connection" — and flips the row's disk state to .failed
    /// with the error message so the user can Remove + redownload instead of
    /// being stuck with a model that says Installed but doesn't work.
    func verifyWhisper(_ id: String, using service: TranscriptionService) async {
        verifyingWhisper.insert(id)
        defer { verifyingWhisper.remove(id) }
        do {
            try await service.ensureLoaded(modelID: id)
            // ensureLoaded succeeded — the model is genuinely usable. The
            // service's currentModelID now reflects that (observable), and
            // we leave whisperStates as .ready.
        } catch {
            whisperStates[id] = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    func verifyLLM(_ id: String, using service: MLXLLMService) async {
        verifyingLLM.insert(id)
        defer { verifyingLLM.remove(id) }
        do {
            // Interactive: the user is sitting in Settings waiting for an
            // answer, and a load evicts whatever container a background
            // (socket) generation is mid-way through anyway — so cancel it
            // first rather than racing it.
            try await LLMScheduler.shared.run(.interactive) {
                try await service.ensureLoaded(modelID: id, progress: nil)
            }
        } catch {
            llmStates[id] = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    func verifyParakeet(_ id: String, using service: ParakeetService) async {
        verifyingParakeet.insert(id)
        defer { verifyingParakeet.remove(id) }
        do {
            try await service.ensureLoaded(modelID: id)
        } catch {
            parakeetStates[id] = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    func verifyDiarization(_ id: String, using service: DiarizerService) async {
        verifyingDiarization.insert(id)
        defer { verifyingDiarization.remove(id) }
        do {
            try await service.ensureLoaded(modelID: id)
        } catch {
            diarizationStates[id] = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Unload (drop from memory, leave files on disk)

    /// Free a Whisper model from memory without touching the on-disk files.
    /// Use to reclaim RAM when switching between models without committing
    /// to a redownload.
    func unloadWhisper(_ id: String, using service: TranscriptionService) {
        service.unload(modelID: id)
    }

    func unloadLLM(_ id: String, using service: MLXLLMService) {
        service.unload(modelID: id)
    }

    func unloadParakeet(_ id: String, using service: ParakeetService) {
        service.unload(modelID: id)
    }

    func unloadDiarization(_ id: String, using service: DiarizerService) {
        service.unload(modelID: id)
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
        let snapshot = ModelStorage.whisperModelDirectory(for: id)
        let metadata = ModelStorage.whisperDownloadMetadataDirectory(for: id)
        let removed = removeDirectory(at: snapshot)
        _ = removeDirectory(at: metadata)
        whisperStates[id] = .notDownloaded
        return removed
    }

    /// Unload (if loaded) and remove a Parakeet model's on-disk files. The
    /// model's storage subdirectory `<parakeetRoot>/<id>/` holds everything
    /// FluidAudio cares about for that variant (weights, vocab, compiled
    /// mlmodelc bundles), so one rm wipes the slate cleanly.
    @discardableResult
    func removeParakeet(_ id: String, using service: ParakeetService) -> Bool {
        service.unload(modelID: id)
        let dir = ParakeetService.storageURL(forID: id)
        let removed = removeDirectory(at: dir)
        parakeetStates[id] = .notDownloaded
        return removed
    }

    /// Unload (if loaded) and remove an LLM model's on-disk files.
    @discardableResult
    func removeLLM(_ id: String, using service: MLXLLMService) -> Bool {
        service.unload(modelID: id)
        let dir = ModelStorage.llmModelDirectory(for: id)
        let removed = removeDirectory(at: dir)
        llmStates[id] = .notDownloaded
        return removed
    }

    /// Unload (if loaded) and remove the diarization bundle from disk. The
    /// whole `<diarizationRoot>/speaker-diarization/` tree is wiped — that's
    /// where FluidAudio's repo snapshot lives, and removing it cleanly forces
    /// a fresh download next time the user asks for diarization.
    @discardableResult
    func removeDiarization(_ id: String, using service: DiarizerService) -> Bool {
        service.unload(modelID: id)
        let dir = ModelStorage.diarizationRoot()
            .appendingPathComponent("speaker-diarization", isDirectory: true)
        let removed = removeDirectory(at: dir)
        diarizationStates[id] = .notDownloaded
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
