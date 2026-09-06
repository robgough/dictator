import Foundation

/// Apple's on-device Foundation model.
///
/// Included for completeness and forward compatibility rather than because it
/// works well today: as of macOS 27 third-party apps only get the ~3B "Core"
/// model with a 4096-token window (see `AppleFoundationAvailability`), which
/// isn't enough room for a meeting transcript — the chunker would shred an
/// hour-long call into dozens of tiny windows and the notes come out
/// incoherent. `ProviderRegistry.qualityNote` says so plainly. If a future OS
/// hands apps a larger window this provider becomes genuinely useful with no
/// code change.
@MainActor
final class AppleFoundationProvider: MeetingLLM {
    let id: String
    let displayName: String
    var isLocal: Bool { true }

    init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.name.isEmpty ? ProviderConfig.Kind.apple.displayName : config.name
    }

    /// The real per-machine figure when the model is available; the macOS 26
    /// backstop otherwise. Never 0 — the chunker divides by this.
    var contextWindowTokens: Int {
        AppleFoundationAvailability.contextSize ?? 4_096
    }

    /// A quarter of the window, floored at 512. Apple counts prompt and reply
    /// against the same budget, so reserving three quarters for the transcript
    /// is the only sane split on a 4K model.
    var maxOutputTokens: Int {
        max(512, contextWindowTokens / 4)
    }

    /// Whether the window is big enough for meeting notes to be worth writing.
    var isMeetingsCapable: Bool { AppleFoundationAvailability.isMeetingsCapable }

    func prepare() async throws {
        guard AppleFoundationAvailability.isUsable else {
            throw MeetingLLMError.unavailable(
                AppleFoundationAvailability.unavailableMessage
                    ?? "Apple's on-device model isn't available on this Mac right now."
            )
        }
        do {
            try await AppleFoundationLLMServiceHolder.shared.ensureReady()
        } catch {
            throw MeetingLLMError.unavailable(error.localizedDescription)
        }
    }

    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String {
        try await prepare()
        return try await MeetingLLMCancellation.runCancellable(cancellation) {
            try await AppleFoundationLLMServiceHolder.shared.complete(
                system: system,
                user: user,
                maxTokens: max(1, maxTokens),
                temperature: temperature
            )
        }
    }

    func healthCheck() async throws -> String {
        try await prepare()
        let reply = try await AppleFoundationLLMServiceHolder.shared.complete(
            system: "Reply with the single word OK. Nothing else.",
            user: "OK",
            maxTokens: 8
        )
        guard !reply.isEmpty else { throw MeetingLLMError.emptyResponse(displayName) }
        return "Apple on-device (\(contextWindowTokens)-token window)"
    }
}
