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

    /// Drop the in-memory WhisperKit pipeline. Called before deleting the
    /// model files from disk so we don't tear them out from under a live
    /// pipeline that's still mmap'ed against them.
    func unload(modelID: String) {
        guard currentModelID == modelID else { return }
        pipe = nil
        currentModelID = nil
    }

    func transcribe(samples: [Float], modelID: String, prompt: String? = nil) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let pipe else {
            throw NSError(domain: "Dictator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Whisper not loaded"])
        }

        // Optionally bias the decoder with a short prompt (the user's name and
        // any vocabulary terms they care about). Whisper treats `promptTokens`
        // as conditioning context — concretely, words that appear there are
        // more likely to be emitted with the same spelling. Tokenisation can
        // only happen once the tokenizer's loaded, so we require an
        // already-loaded pipeline at this point (ensureLoaded above).
        var decodeOptions: DecodingOptions? = nil
        if let prompt, !prompt.isEmpty, let tokens = pipe.tokenizer?.encode(text: prompt), !tokens.isEmpty {
            decodeOptions = DecodingOptions(promptTokens: tokens)
        }

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: decodeOptions)
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
