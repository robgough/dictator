import Foundation
@preconcurrency import WhisperKit

@MainActor
@Observable
final class TranscriptionService: ASREngine {
    /// The ID of the model currently held in memory (nil when nothing is loaded).
    /// Exposed read-only so the Settings UI can show a "Loaded" badge.
    private(set) var currentModelID: String?
    /// True while `ensureLoaded` is running. Drives a spinner on the Verify
    /// button so the user sees that the load is in progress, not stalled.
    private(set) var isLoading: Bool = false
    @ObservationIgnored private var pipe: WhisperKit?

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
        isLoading = true
        defer { isLoading = false }

        // Point WhisperKit at the local folder whenever the variant is already
        // downloaded, and turn `download` off with it.
        //
        // `WhisperKit.setupModels` takes `modelFolder` as its first branch and
        // returns without touching the network; the `download: true` fallback
        // underneath it calls `hubApi.getFilenames` on *every* load, even when
        // every file is already on disk. That made each cold load a callout to
        // huggingface.co carrying the user's IP, their model, and the time —
        // the same defect as the MLX path (see `MLXLLMService.ensureLoaded`).
        // Using a model we already have needs no network.
        //
        // The tokenizer is already local-first inside WhisperKit
        // (`ModelUtilities.loadTokenizer` searches the download base before it
        // considers the Hub), so `modelFolder` closes the last remote call.
        let localFolder = ModelStorage.whisperModelDirectory(for: modelID)
        let isDownloaded = ModelStorage.downloadIsComplete(
            snapshot: localFolder,
            metadata: ModelStorage.whisperDownloadMetadataDirectory(for: modelID),
            isReady: { contents in contents.contains { $0.hasSuffix(".mlmodelc") } }
        )

        func makeKit(localOnly: Bool) async throws -> WhisperKit {
            let config = WhisperKitConfig(
                model: modelID,
                downloadBase: ModelStorage.whisperRoot(),
                modelRepo: "argmaxinc/whisperkit-coreml",
                modelFolder: localOnly ? localFolder.path : nil,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: !localOnly
            )
            return try await WhisperKit(config)
        }

        let kit: WhisperKit
        if isDownloaded {
            do {
                kit = try await makeKit(localOnly: true)
            } catch {
                // Local copy won't load — repair it through the Hub rather
                // than leaving transcription broken.
                MicLog.log("Whisper local load failed (\(error.localizedDescription)); repairing via Hub")
                kit = try await makeKit(localOnly: false)
            }
        } else {
            kit = try await makeKit(localOnly: false)
        }
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

    /// ASREngine conformance. Defaults `prompt` to nil so callers going through
    /// the protocol don't need to know about WhisperKit's biasing knob. The
    /// 3-arg form below stays available on the concrete type if biasing is
    /// ever revived (see `whisper_prompt_biasing.md` memory note for why we
    /// parked it).
    func transcribe(samples: [Float], modelID: String) async throws -> String {
        try await transcribe(samples: samples, modelID: modelID, prompt: nil)
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
