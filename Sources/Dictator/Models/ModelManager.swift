import Foundation
import Observation

enum ModelDownloadState: Equatable, Sendable {
    case unknown
    case notDownloaded
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

    private init() {
        refreshCachedStates()
    }

    func refreshCachedStates() {
        for m in ModelCatalog.whisperModels {
            whisperStates[m.id] = isWhisperOnDisk(id: m.id) ? .ready : .notDownloaded
        }
        for m in ModelCatalog.llmModels {
            llmStates[m.id] = isLLMOnDisk(id: m.id) ? .ready : .notDownloaded
        }
    }

    // MARK: - Disk presence checks (cheap heuristics; loading actually validates)

    private func isWhisperOnDisk(id: String) -> Bool {
        // HubApi layout: <root>/models/argmaxinc/whisperkit-coreml/<id>/
        // A folder with at least one .mlmodelc inside counts as "downloaded".
        let candidate = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: candidate.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") }
    }

    private func isLLMOnDisk(id: String) -> Bool {
        // HubApi layout: <root>/models/<repoId>/
        let candidate = ModelStorage.llmRoot()
            .appendingPathComponent("models/\(id)", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: candidate.path)) ?? []
        // Treat any non-dotfile sibling (weights, tokenizer, config) as "downloaded".
        return contents.contains { !$0.hasPrefix(".") }
    }

    // MARK: - Download triggers (call into the services so it warms the cache too)

    func downloadWhisper(_ id: String, using service: TranscriptionService) async {
        whisperStates[id] = .downloading(0)
        do {
            try await service.download(modelID: id) { [weak self] progress in
                self?.whisperStates[id] = .downloading(progress)
            }
            whisperStates[id] = .ready
        } catch {
            whisperStates[id] = .failed(error.localizedDescription)
        }
    }

    func downloadLLM(_ id: String, using service: LLMService) async {
        llmStates[id] = .downloading(0)
        do {
            try await service.ensureLoaded(modelID: id) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.llmStates[id] = .downloading(progress)
                }
            }
            llmStates[id] = .ready
        } catch {
            llmStates[id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Deletion

    /// Unload (if loaded) and remove a Whisper model's on-disk files. Returns
    /// whether the directory was found and removed.
    @discardableResult
    func removeWhisper(_ id: String, using service: TranscriptionService) -> Bool {
        service.unload(modelID: id)
        let dir = ModelStorage.whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(id)", isDirectory: true)
        let removed = removeDirectory(at: dir)
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
