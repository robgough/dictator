import Foundation

/// An MLX checkpoint loaded into this process, through the same
/// `MLXLLMServiceHolder.shared` singleton the Models tab downloads and
/// verifies with — so a model warmed by a "Verify" tap is the same container a
/// meeting then writes notes on.
///
/// This is the fallback when Dictator isn't running (or isn't sharing), and the
/// only provider that puts a multi-gigabyte model in *this* app's address
/// space. `MeetingSession.reclaimAfterProcessing` releases the MLX GPU cache
/// after a post-pass precisely because of this provider.
@MainActor
final class LocalMLXProvider: MeetingLLM {
    let id: String
    let displayName: String
    /// The checkpoint to load. Taken from `ProviderConfig.modelID` when set,
    /// otherwise `MeetingsSettings.localLLMModelID`.
    private(set) var modelID: String

    var isLocal: Bool { true }

    init(config: ProviderConfig, fallbackModelID: String) {
        self.id = config.id
        self.displayName = config.name.isEmpty ? ProviderConfig.Kind.localMLX.displayName : config.name
        let configured = config.modelID?.trimmingCharacters(in: .whitespaces) ?? ""
        self.modelID = configured.isEmpty ? fallbackModelID : configured
    }

    /// The registry re-points an existing instance rather than rebuilding it
    /// when only the model id changed, so a container that's already warm for
    /// the new id isn't dropped.
    func update(modelID newValue: String) {
        guard !newValue.isEmpty else { return }
        modelID = newValue
    }

    /// The catalog's native context window for this checkpoint, or the
    /// catalog floor for an id we don't know (someone hand-edited settings).
    var contextWindowTokens: Int {
        ModelCatalog.llm(id: modelID)?.contextWindowTokens ?? ModelCatalog.fallbackContextWindowTokens
    }

    /// Matches the runaway-generation guard `MLXLLMService.assist` uses. MLX
    /// grows its KV cache on demand, so this costs nothing until a reply
    /// actually runs long.
    var maxOutputTokens: Int { 8_192 }

    /// The catalog entry, when the id is one we ship. nil for a hand-set id.
    var catalogEntry: LLMModel? { ModelCatalog.llm(id: modelID) }

    /// Whether the weights are on disk. The registry uses this before offering
    /// this provider as a fallback — silently kicking off a multi-gigabyte
    /// download because a meeting ended is the wrong behaviour.
    var isDownloaded: Bool {
        ModelManager.shared.llmStates[modelID] == .ready
    }

    /// Whether notes written by this model are worth keeping. False for the
    /// small checkpoints; surfaced as `ProviderRegistry.qualityNote` rather
    /// than blocking, since it's the user's Mac and their call.
    var isMeetingsCapable: Bool {
        ModelCatalog.llm(id: modelID)?.meetingsCapable ?? false
    }

    // MARK: - MeetingLLM

    func prepare() async throws {
        guard isDownloaded else {
            let name = catalogEntry?.displayName ?? modelID
            throw MeetingLLMError.unavailable("\(name) isn't downloaded yet — get it on the Models tab.")
        }
        let service = MLXLLMServiceHolder.shared
        service.modelID = modelID
        do {
            try await service.ensureLoaded(modelID: modelID)
        } catch {
            throw MeetingLLMError.unavailable("Couldn't load \(catalogEntry?.displayName ?? modelID): \(error.localizedDescription)")
        }
    }

    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String {
        try await prepare()
        let modelID = self.modelID
        // `LLMEngine.complete` takes no cancellation closure, so cancellation
        // is expressed as task cancellation, which MLX honours between tokens.
        return try await MeetingLLMCancellation.runCancellable(cancellation) {
            let service = MLXLLMServiceHolder.shared
            service.modelID = modelID
            return try await service.complete(system: system, user: user,
                                              maxTokens: max(1, maxTokens),
                                              temperature: temperature)
        }
    }

    func healthCheck() async throws -> String {
        try await prepare()
        let reply = try await MLXLLMServiceHolder.shared.complete(
            system: "Reply with the single word OK. Nothing else.",
            user: "OK",
            maxTokens: 8
        )
        guard !reply.isEmpty else { throw MeetingLLMError.emptyResponse(displayName) }
        return catalogEntry?.displayName ?? modelID
    }
}
