import Foundation
@preconcurrency import WhisperKit

@MainActor
final class TranscriptionService {
    private var currentModelID: String?
    private var pipe: WhisperKit?

    /// Downloads the model files (no load) and reports real per-file progress.
    /// Use this from the Settings "Download" button.
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        // WhisperKit's progressCallback isn't typed @Sendable, so we bridge through a
        // nonisolated helper to keep Swift 6 strict concurrency happy.
        let onFraction: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(fraction) }
        }
        try await Self.runWhisperKitDownload(
            modelID: modelID,
            downloadBase: ModelStorage.whisperRoot(),
            onFraction: onFraction
        )
    }

    /// Loads the model into memory. Triggers a download if not already on disk.
    func ensureLoaded(modelID: String) async throws {
        if currentModelID == modelID, pipe != nil { return }
        pipe = nil
        currentModelID = nil

        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: ModelStorage.whisperRoot(),
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        pipe = kit
        currentModelID = modelID
    }

    func transcribe(samples: [Float], modelID: String) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let pipe else {
            throw NSError(domain: "Dictator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Whisper not loaded"])
        }
        let results = try await pipe.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ")
    }

    // MARK: - Nonisolated bridge

    private nonisolated static func runWhisperKitDownload(
        modelID: String,
        downloadBase: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: modelID,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in
                onFraction(p.fractionCompleted)
            }
        )
    }
}
