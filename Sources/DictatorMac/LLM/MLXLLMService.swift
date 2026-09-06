import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// MLX-Swift backed LLM engine. Downloads a HuggingFace checkpoint via Hub, loads
/// it into a MainActor-isolated `ModelContainer`, and runs the dictation /
/// assistant passes on it.
///
/// Identity is carried by the `modelID` property — the dispatcher in Pipeline
/// (`activeLLM()`) writes the currently-selected MLX model id into it before each
/// per-call API. `ensureLoaded`/`download`/`unload(modelID:)` are *additional*
/// public methods used by ModelManager's per-model download/verify/unload UI;
/// they're not part of the `LLMEngine` protocol.
@MainActor
@Observable
final class MLXLLMService: LLMEngine, LLMUsageReporting {
    /// The MLX model id this engine should act as for the next per-pass call.
    /// Set by Pipeline's `activeLLM()` dispatch before any pipeline-driven call.
    /// The download / verify code paths take an explicit modelID parameter so
    /// they can act on a model that isn't the currently configured one.
    var modelID: String?

    /// The ID of the model currently held in memory (nil when nothing is loaded).
    /// Exposed read-only so the Settings UI can show a "Loaded" badge.
    private(set) var currentModelID: String?
    /// True while `ensureLoaded` is running.
    private(set) var isLoading: Bool = false
    @ObservationIgnored private var container: ModelContainer?

    /// True when a model container is resident right now. The LLM socket
    /// server answers `status` with this (paired with `currentModelID`) so a
    /// remote caller can tell "borrow it" from "load your own" — the server
    /// never loads on a remote request, so an un-loaded engine must report
    /// itself as such rather than looking available and then stalling for 30
    /// seconds.
    var isLoaded: Bool { container != nil }

    /// True when *this specific* model is the one resident. `isLoaded` alone
    /// isn't enough: the user can switch models in Settings without the old
    /// container being dropped until the next load.
    func isLoaded(modelID: String) -> Bool {
        container != nil && currentModelID == modelID
    }

    var assistantInputTokenBudget: Int {
        let id = modelID ?? ""
        let context = ModelCatalog.llm(id: id)?.contextWindowTokens
            ?? ModelCatalog.fallbackContextWindowTokens
        return max(2_000, context - ConversationContextBudget.nonInputReservationTokens)
    }

    /// Downloads the model files (no compile, no load) and reports fractional
    /// progress. Use this from the Settings / Onboarding "Download" buttons —
    /// `ensureLoaded` does the heavy compile + RAM-resident load on top.
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let onFraction: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(fraction) }
        }
        try await Self.runHubDownload(
            modelID: modelID,
            downloadBase: ModelStorage.llmRoot(),
            onFraction: onFraction
        )
    }

    func ensureLoaded(modelID: String, progress: (@Sendable @MainActor (Double) -> Void)? = nil) async throws {
        if currentModelID == modelID, container != nil { return }
        container = nil
        currentModelID = nil
        isLoading = true
        defer { isLoading = false }

        // Vendored architectures (Gemma 4) must be in the type registry before
        // the factory reads the checkpoint's model_type. Idempotent.
        await Gemma4Registration.registerIfNeeded()

        // The Hub-backed path, used only when the weights aren't already here.
        func loadFromHub() async throws -> ModelContainer {
            try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(downloadBase: ModelStorage.llmRoot()),
                using: HubTokenizerLoader(),
                configuration: ModelConfiguration(id: modelID)
            ) { p in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress?(fraction) }
            }
        }

        // Load straight off disk whenever the model is already downloaded.
        //
        // The Hub path can't be used for this: mlx-swift-lm's `resolve()` calls
        // the downloader unconditionally for an `.id` configuration, and
        // `HubApi.snapshot` only skips the network when the machine is fully
        // offline (`shouldUseOfflineMode` is just `!isConnected`). So every
        // cold load re-listed the repo and revalidated each file against
        // huggingface.co, sending the user's IP, which model they run, and the
        // time they ran it — on every Assistant Mode activation, and on every
        // dictation or meeting pass that reloaded the model. Using a model we
        // already have needs no network at all.
        //
        // `loadContainer(from directory:)` takes no downloader, so it cannot
        // reach the network even by accident. Nothing is lost by going through
        // it: we build a bare `ModelConfiguration(id:)` with no registry
        // metadata, so the `.directory` form resolves to the same thing.
        let localDirectory = ModelStorage.llmModelDirectory(for: modelID)
        let isDownloaded = ModelStorage.downloadIsComplete(
            snapshot: localDirectory,
            metadata: ModelStorage.llmDownloadMetadataDirectory(for: modelID),
            isReady: { contents in contents.contains { !$0.hasPrefix(".") } }
        )

        let loaded: ModelContainer
        if isDownloaded {
            do {
                loaded = try await LLMModelFactory.shared.loadContainer(
                    from: localDirectory,
                    using: HubTokenizerLoader()
                )
            } catch {
                // The on-disk copy is unusable — truncated, or a layout we
                // didn't anticipate. Repair it through the Hub rather than
                // leaving the user with a model that won't load.
                MicLog.log("LLM local load failed (\(error.localizedDescription)); repairing via Hub")
                loaded = try await loadFromHub()
            }
        } else {
            loaded = try await loadFromHub()
        }
        container = loaded
        currentModelID = modelID
    }

    func ensureReady() async throws {
        guard let id = modelID else {
            throw NSError(domain: "Dictator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MLX LLM engine has no model selected."])
        }
        try await ensureLoaded(modelID: id)
    }

    /// Download-only bridge (mlx-swift-lm 3.x dropped `MLXLMCommon.downloadModel`;
    /// calling our `Downloader` directly is the equivalent). Nonisolated so the
    /// actual file download runs on the cooperative pool, not the main actor —
    /// the `await` at the call site suspends the caller cleanly. Mirrors the
    /// same shape as `TranscriptionService.runWhisperKitDownload` /
    /// `ParakeetService.runDownload`.
    private nonisolated static func runHubDownload(
        modelID: String,
        downloadBase: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        let downloader = HubDownloader(downloadBase: downloadBase)
        _ = try await downloader.download(
            id: modelID,
            revision: nil,
            matching: HubDownloader.modelFilePatterns,
            useLatest: false
        ) { p in
            onFraction(p.fractionCompleted)
        }
    }

    /// Drop the in-memory MLX container. Called before deleting the model
    /// files from disk so we don't tear them out from under a live container
    /// that has them mmap'ed.
    func unload(modelID: String) {
        guard currentModelID == modelID else { return }
        container = nil
        currentModelID = nil
    }

    /// `LLMEngine` protocol method — drops whatever's currently loaded.
    func unload() {
        container = nil
        currentModelID = nil
    }

    /// Hand MLX's GPU buffer pool back to the system *without* evicting the
    /// loaded model. The pool is capped (`AppState.bootstrap` sets a 512 MB
    /// `cacheLimit`) but a meeting's many live-notes + summary passes fill it;
    /// clearing it after the post-pass reclaims that memory while keeping the
    /// container warm, so a dictation or another meeting right after stays fast.
    func releaseGPUCache() {
        MLX.GPU.clearCache()
    }

    func format(text: String, systemPrompt: String) async throws -> String {
        // Tight cap on the formatter — a correctly formatted version is almost
        // always within ~15% of the input length. The real defense against the
        // "model answered the question" failure mode is the word-count growth
        // check in Pipeline.passOnePreservesContent(); the cap here is just a
        // belt-and-braces perf optimisation so a wandering model doesn't generate
        // an entire essay before we reject it.
        try await runFormatPass(text: text, systemPrompt: systemPrompt,
                                maxTokenMultiplier: 1.20, maxTokenConstant: 8)
    }

    private func runFormatPass(text: String, systemPrompt: String,
                               maxTokenMultiplier: Double, maxTokenConstant: Int,
                               cancellation: @Sendable @escaping () -> Bool = { Task.isCancelled }) async throws -> String {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        // Wrap the transcript in `<<< >>>` so the model treats it as data, not a
        // question or instruction. Without this signal, small models slip into
        // "helpful assistant" mode and answer the user. The `Input:/Output:` labels
        // we used previously caused the model to echo the wrapping back — the
        // post-processor in LLMTextUtilities.clean() handles any residual echo
        // defensively.
        let userText = LLMTextUtilities.wrapAsData(text)

        let generated = try await container.perform { (ctx: ModelContext) -> (output: String, inTokens: Int, outTokens: Int) in
            let userInput = UserInput(chat: [
                .system(systemPrompt),
                .user(userText)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let approxInputTokens = max(8, text.count / 4)
            let maxTokens = min(2048,
                                max(24,
                                    Int(Double(approxInputTokens) * maxTokenMultiplier) + maxTokenConstant))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in cancellation() ? .stop : .more }
            )
            return (result.output, result.promptTokenCount, result.generationTokenCount)
        }

        UsageStatsStore.shared.recordLLMTokens(in: generated.inTokens, out: generated.outTokens)
        return LLMTextUtilities.clean(generated.output)
    }

    /// Plain system+user completion. No `<<< >>>` wrapping — the caller owns the
    /// user message's shape (the paragraph pass sends a numbered sentence list,
    /// not a transcript to transform) — and the caller states the reply budget
    /// outright rather than deriving it from the input length, because a
    /// structured reply's size has nothing to do with how much text it describes.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await completeReportingUsage(system: system, user: user, maxTokens: maxTokens).text
    }

    /// The real implementation, plus the token counts MLX already hands back.
    /// `complete` throws them away (usage is recorded here either way); the LLM
    /// socket server keeps them, because the process on the other end of the
    /// socket can't see `UsageStatsStore`.
    func completeReportingUsage(system: String, user: String, maxTokens: Int) async throws -> LLMCompletionResult {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }
        let cap = max(1, maxTokens)
        let generated = try await container.perform { (ctx: ModelContext) -> (output: String, inTokens: Int, outTokens: Int) in
            let userInput = UserInput(chat: [
                .system(system),
                .user(user)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: cap, temperature: 0.0, topP: 1.0)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in Task.isCancelled ? .stop : .more }
            )
            return (result.output, result.promptTokenCount, result.generationTokenCount)
        }
        UsageStatsStore.shared.recordLLMTokens(in: generated.inTokens, out: generated.outTokens)
        return LLMCompletionResult(
            text: LLMTextUtilities.clean(generated.output),
            promptTokens: generated.inTokens,
            completionTokens: generated.outTokens
        )
    }

    /// Assistant Mode: takes an optional snippet of text the user had selected plus
    /// a spoken instruction about what to do. The model classifies its own reply as
    /// either REPLACE (transform-in-place / insert-at-cursor) or DRAFT (clipboard-only
    /// output). When the classifier marker is missing or malformed, we default to
    /// .draft — non-destructive. Selection may be nil (user had nothing selected
    /// and wants something generated, e.g. "make me a list of 10 things here").
    ///
    /// `priorTurns` carries the conversation history when this is a follow-up turn.
    /// `summary`, if non-nil, is a compacted stand-in for earlier turns that no
    /// longer fit in the context window — rendered as a single "[Earlier
    /// conversation summary]" user-role block before the verbatim turns.
    func assist(
        selection: String?,
        instruction: String,
        systemPrompt: String,
        priorTurns: [ConversationTurn] = [],
        summary: String? = nil,
        context: InsertionContext?,
        cancellation: @Sendable @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> AssistantResult {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        let currentUserText = LLMTextUtilities.renderAssistantUserMessage(selection: selection, instruction: instruction)
        // Build the surrounding-document block (if any) outside the perform
        // closure so only a Sendable String crosses into it.
        let contextBlock: String? = (context?.hasPromptMaterial == true) ? context?.assistantPromptBlock : nil

        let generated = try await container.perform { (ctx: ModelContext) -> (output: String, inTokens: Int, outTokens: Int) in
            var messages: [Chat.Message] = [.system(systemPrompt)]

            if let summary, !summary.isEmpty {
                messages.append(.user("""
                [Earlier conversation summary — older turns have been compacted to fit context]
                <<<
                \(summary)
                >>>
                """))
            }

            for turn in priorTurns {
                messages.append(.user(LLMTextUtilities.renderAssistantUserMessage(selection: turn.selection, instruction: turn.instruction)))
                // Re-include the MODE: marker so the model keeps emitting it on the
                // next turn — without it, follow-up replies often drop the marker
                // and we lose REPLACE intent (parseAssistant falls back to .draft).
                messages.append(.assistant("MODE: \(turn.mode.rawValue.uppercased())\n\(turn.reply)"))
            }

            // Document context for the current turn, just before the current
            // user message it describes. (Prior turns carry no context — the
            // surrounding text is only meaningful for where the user is now.)
            if let contextBlock {
                messages.append(.user(contextBlock))
            }
            messages.append(.user(currentUserText))

            let userInput = UserInput(chat: messages)
            let lmInput = try await ctx.processor.prepare(input: userInput)
            // Assistant Mode is free-form generation — the user's instruction governs
            // length ("give me 100 emojis", "draft a long email"). The cap here is
            // purely a runaway-generation guard, not a length policy, so it's set
            // generously. 8192 tokens ≈ ~6000 words, comfortably above any reasonable
            // single dictation-driven request while still bounding pathological loops.
            // RAM cost is paid only when generation actually reaches the cap (MLX
            // grows the KV cache on demand); worst case ≈ 1 GB on a typical 3B model.
            let params = GenerateParameters(maxTokens: 8192, temperature: 0.2, topP: 0.95)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in cancellation() ? .stop : .more }
            )
            return (result.output, result.promptTokenCount, result.generationTokenCount)
        }

        UsageStatsStore.shared.recordLLMTokens(in: generated.inTokens, out: generated.outTokens)
        return LLMTextUtilities.parseAssistant(generated.output)
    }

    /// Compacts a slice of conversation turns plus any pre-existing summary
    /// into a single short paragraph that preserves the load-bearing context
    /// (user intent, decisions, names, drafted content) the model needs to
    /// keep continuity. Failure throws — the caller surfaces a "conversation
    /// too long" message rather than silently dropping context.
    func summariseConversation(
        turns: [ConversationTurn],
        priorSummary: String?,
        cancellation: @Sendable @escaping () -> Bool = { Task.isCancelled }
    ) async throws -> String {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        let rendered = turns.map { turn -> String in
            let sel = turn.selection.flatMap { $0.isEmpty ? nil : $0 }
            let selLine = sel.map { "Selection: \($0)" } ?? "Selection: (none)"
            return """
            ---
            User: \(turn.instruction)
            \(selLine)
            Assistant (MODE: \(turn.mode.rawValue.uppercased())):
            \(turn.reply)
            """
        }.joined(separator: "\n")

        let priorBlock: String
        if let priorSummary, !priorSummary.isEmpty {
            priorBlock = """
            Previous summary so far:
            <<<
            \(priorSummary)
            >>>

            """
        } else {
            priorBlock = ""
        }

        let userText = """
        \(priorBlock)Conversation turns to compact:
        <<<
        \(rendered)
        >>>
        """

        let generated = try await container.perform { (ctx: ModelContext) -> (output: String, inTokens: Int, outTokens: Int) in
            let userInput = UserInput(chat: [
                .system(LLMTextUtilities.summariserSystemPrompt),
                .user(userText)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: 512, temperature: 0.2, topP: 0.95)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in cancellation() ? .stop : .more }
            )
            return (result.output, result.promptTokenCount, result.generationTokenCount)
        }

        UsageStatsStore.shared.recordLLMTokens(in: generated.inTokens, out: generated.outTokens)
        let cleaned = LLMTextUtilities.clean(generated.output)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "Dictator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Summariser returned no text"])
        }
        return cleaned
    }
}
