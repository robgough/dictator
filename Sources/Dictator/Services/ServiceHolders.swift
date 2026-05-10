import Foundation

/// Settings pane needs to trigger a manual download via the same service instance
/// the Pipeline uses, so model load is amortised. Holders are main-actor isolated
/// because both services run on the main actor.
@MainActor
enum TranscriptionServiceHolder {
    static let shared = TranscriptionService()
}

@MainActor
enum LLMServiceHolder {
    static let shared = LLMService()
}
