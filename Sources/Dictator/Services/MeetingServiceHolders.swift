import Foundation

/// Meeting-specific service holders. The general-purpose ones (Whisper, MLX,
/// Apple Foundation, dictation Parakeet) live in
/// `Sources/DictatorMac/Services/ServiceHolders.swift` so both mac apps get
/// them; these two stay here until the meetings code moves into the Dictator
/// Meetings app.

/// Meeting-dedicated Parakeet pipeline. Separate instance from
/// `ParakeetServiceHolder` (dictation) so meeting ASR runs on its own serial
/// `AsrManager` actor and a long post-pass can't block a dictation; it borrows
/// the dictation service's loaded weights when they're warm rather than loading
/// a second copy. See `MeetingParakeetService`.
@MainActor
enum MeetingParakeetServiceHolder {
    static let shared = MeetingParakeetService()
}

/// FluidAudio offline speaker-diarization pipeline. Loaded on demand by the
/// Meetings post-capture flow; the Models pane Verify button also reaches in
/// here so settings + pipeline share one warm model.
@MainActor
enum DiarizerServiceHolder {
    static let shared = DiarizerService()
}
