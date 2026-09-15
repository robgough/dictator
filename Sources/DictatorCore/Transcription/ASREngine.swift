import Foundation

/// Shared surface for speech-to-text engines. Pipeline depends on this so it
/// can dispatch over Whisper or Parakeet without caring which is active.
///
/// Engine-specific knobs (e.g. WhisperKit's `promptTokens` biasing) stay on
/// the concrete service — the protocol exposes only what every engine has.
@MainActor
protocol ASREngine: AnyObject {
    /// ID of the model currently held in memory (nil when nothing loaded).
    var currentModelID: String? { get }
    /// True while `ensureLoaded` is in flight.
    var isLoading: Bool { get }

    /// Stages weights into the per-engine on-disk cache, reporting fractional
    /// progress. Does not load into memory — paired with `ensureLoaded` from
    /// the Settings download flow so the user can pre-cache without waiting
    /// on compile + load.
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws

    /// Loads the model into memory. Triggers a download first if missing.
    func ensureLoaded(modelID: String) async throws

    /// Drops the in-memory pipeline for `modelID` (no-op if a different model
    /// is loaded). Files stay on disk.
    func unload(modelID: String)

    /// Transcribe 16 kHz mono Float32 samples.
    ///
    /// `language` is a *hint*, never a requirement: both engines detect the
    /// language themselves and both do better when told which one to expect.
    /// `.auto` keeps the historic behaviour of letting them work it out, and
    /// an engine is free to ignore a language it doesn't know about.
    func transcribe(samples: [Float], modelID: String, language: DictationLanguage) async throws -> String
}

extension ASREngine {
    /// Convenience for the callers that have no opinion about language — the
    /// meetings pipeline, the mic test, the dictionary tester. Keeps the
    /// protocol to one requirement while leaving every existing call site
    /// untouched.
    func transcribe(samples: [Float], modelID: String) async throws -> String {
        try await transcribe(samples: samples, modelID: modelID, language: .auto)
    }
}
