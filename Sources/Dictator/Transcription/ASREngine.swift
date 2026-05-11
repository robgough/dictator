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
    func transcribe(samples: [Float], modelID: String) async throws -> String
}
