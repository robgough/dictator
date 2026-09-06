import Foundation
@preconcurrency import FluidAudio

/// Meeting-dedicated Parakeet ASR. Mirrors `ParakeetService`'s transcribe
/// surface but runs on its OWN `AsrManager` (a FluidAudio actor) so meeting
/// work — the live draft stream and the long post-capture pass — can never
/// serialize ahead of, or block, a dictation the user fires during or right
/// after a meeting. The two used to share one `AsrManager`; a 1–2 hour
/// post-pass on that single serial actor left a subsequent dictation stuck on
/// "transcribing" until the meeting finished.
///
/// Weights are shared, not duplicated. FluidAudio's `AsrModels` is a value of
/// CoreML model references, so when the dictation service already has the model
/// warm we borrow its `AsrModels` and only spin up a second manager (cheap —
/// just decoder state + buffers). Two managers calling the shared CoreML models
/// concurrently is safe: it's exactly FluidAudio's own long-audio worker-pool
/// pattern (N manager clones over one `AsrModels`). When dictation isn't using
/// Parakeet we load our own copy and release it after the meeting (see
/// `unload`), so a meeting never leaves a second model set resident.
@MainActor
final class MeetingParakeetService {
    private var currentModelID: String?
    private var manager: AsrManager?
    /// Our own loaded weights, set only when we couldn't borrow the dictation
    /// service's — tracked so `unload` frees them. A *borrowed* `AsrModels` is
    /// owned by the dictation service and must be left alone.
    private var ownModels: AsrModels?

    /// Load a manager for `modelID`, borrowing the dictation service's weights
    /// when they're already warm, else loading our own.
    func ensureLoaded(modelID: String) async throws {
        if currentModelID == modelID, manager != nil { return }
        unload()

        let models: AsrModels
        if let borrowed = ParakeetServiceHolder.shared.loadedModelsIfReady(modelID: modelID) {
            models = borrowed
        } else {
            guard let version = ParakeetService.version(forID: modelID) else {
                throw NSError(domain: "Dictator", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Unknown Parakeet model: \(modelID)"])
            }
            let loaded = try await AsrModels.downloadAndLoad(
                to: ParakeetService.storageURL(forID: modelID),
                version: version
            )
            ownModels = loaded
            models = loaded
        }
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(models)
        self.manager = mgr
        self.currentModelID = modelID
    }

    /// Drop the meeting manager (and our own weights if we loaded them). The
    /// borrowed-weights case leaves the dictation service untouched. Called
    /// after a meeting's post-pass completes so a meeting doesn't leave a
    /// second model set resident once it's done.
    func unload() {
        manager = nil
        ownModels = nil
        currentModelID = nil
    }

    /// Transcribe a 16 kHz mono Float32 buffer. FluidAudio auto-chunks inputs
    /// longer than its window, so this handles both the short live chunks and
    /// the whole-track post-pass.
    func transcribe(samples: [Float], modelID: String) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let manager else {
            throw NSError(domain: "Dictator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet not loaded"])
        }
        var state = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &state, language: nil).text
    }

    /// Word-aligned transcription. Same audio shape as `transcribe`, surfacing
    /// `(start, end)` word timings the diarizer needs to attribute words.
    func transcribeWithTimestamps(samples: [Float], modelID: String) async throws -> [TimedWord] {
        try await ensureLoaded(modelID: modelID)
        guard let manager else {
            throw NSError(domain: "Dictator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet not loaded"])
        }
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return ParakeetService.coalesceWords(from: timings)
    }
}
