import Foundation
@preconcurrency import FluidAudio

/// Parakeet TDT speech-to-text. Mirrors the surface of `TranscriptionService`
/// so both engines slot into Pipeline through the same protocol.
///
/// Storage layout. FluidAudio's `AsrModels.download(to:)` writes the CoreML
/// bundles into `<targetDir>.deletingLastPathComponent()/<repo.folderName>/`,
/// i.e. it treats the supplied URL as the *final repo dir* and uses its parent
/// as the working root. We pass `ModelStorage.parakeetRoot()/<id>` so every
/// variant lives at `~/Library/Application Support/Dictator/Models/parakeet/<id>/`
/// alongside the existing whisper/llm trees.
@MainActor
@Observable
final class ParakeetService: ASREngine {
    /// ID of the model currently held in memory (nil when nothing loaded).
    private(set) var currentModelID: String?
    /// True while `ensureLoaded` is running. Drives the Verify-button spinner.
    private(set) var isLoading: Bool = false

    @ObservationIgnored private var models: AsrModels?
    @ObservationIgnored private var manager: AsrManager?

    /// Resolve a catalogue ID to the FluidAudio version enum. Catalogue IDs
    /// happen to be the same string as `AsrModelVersion.repo.folderName`,
    /// so we match on that to stay loosely coupled to FluidAudio's naming.
    static func version(forID id: String) -> AsrModelVersion? {
        switch id {
        case "parakeet-tdt-0.6b-v3": return .v3
        case "parakeet-tdt-0.6b-v2": return .v2
        default: return nil
        }
    }

    /// Directory FluidAudio reads/writes for this variant. Both `download`
    /// and `load` are called with the same URL.
    static func storageURL(forID id: String) -> URL {
        ModelStorage.parakeetRoot().appendingPathComponent(id, isDirectory: true)
    }

    /// Whether all required model files for `id` are on disk.
    static func modelsExist(id: String) -> Bool {
        guard let version = version(forID: id) else { return false }
        return AsrModels.modelsExist(at: storageURL(forID: id), version: version)
    }

    /// Download the model files (no load) and report fractional progress.
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard let version = Self.version(forID: modelID) else {
            throw NSError(domain: "Dictator", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown Parakeet model: \(modelID)"])
        }
        let onFraction: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(fraction) }
        }
        try await Self.runDownload(
            version: version,
            to: Self.storageURL(forID: modelID),
            onFraction: onFraction
        )
    }

    /// Load the model into memory. Downloads first if not already on disk.
    func ensureLoaded(modelID: String) async throws {
        if currentModelID == modelID, manager != nil { return }
        manager = nil
        models = nil
        currentModelID = nil
        isLoading = true
        defer { isLoading = false }

        guard let version = Self.version(forID: modelID) else {
            throw NSError(domain: "Dictator", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown Parakeet model: \(modelID)"])
        }

        // downloadAndLoad is idempotent on disk — if the files are already there
        // it short-circuits the network and goes straight to compile + load.
        let loaded = try await AsrModels.downloadAndLoad(
            to: Self.storageURL(forID: modelID),
            version: version
        )
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(loaded)
        self.models = loaded
        self.manager = mgr
        self.currentModelID = modelID
    }

    /// Drop the in-memory Parakeet pipeline. Called before deleting the
    /// model files from disk so we don't tear them out from under a live
    /// pipeline that's still mmap'ed against them.
    func unload(modelID: String) {
        guard currentModelID == modelID else { return }
        manager = nil
        models = nil
        currentModelID = nil
    }

    /// Transcribe a 16 kHz mono Float32 sample buffer. The recorder already
    /// produces audio in that shape, so no conversion is needed here.
    func transcribe(samples: [Float], modelID: String) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let manager else {
            throw NSError(domain: "Dictator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet not loaded"])
        }
        // TDT decoders are stateful (RNN-T carries hidden state between chunks
        // when streaming). We're doing one-shot per recording, so a fresh state
        // per call is the right semantics — no leakage between dictations.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        return result.text
    }

    // MARK: - Nonisolated bridge
    //
    // FluidAudio's progressHandler is `@Sendable (DownloadProgress) -> Void`.
    // We funnel that to a Sendable fraction-only closure so the MainActor
    // hop happens inside the closure body, away from the call site's actor.

    private nonisolated static func runDownload(
        version: AsrModelVersion,
        to directory: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await AsrModels.download(
            to: directory,
            version: version,
            progressHandler: { p in
                onFraction(p.fractionCompleted)
            }
        )
    }
}
