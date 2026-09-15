import CoreGraphics
import CoreImage
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// MLX-Swift backed LLM engine. Downloads a HuggingFace checkpoint via Hub, loads
/// it into a MainActor-isolated `ModelContainer`, and runs the dictation /
/// assistant passes on it.
///
/// Identity is carried by the `modelID` property — the dispatcher in Pipeline
/// (`activeLLM()`) writes the currently-selected MLX model id into it before each
/// per-call API. `ensureLoaded`/`download`/`unload(modelID:)` are *additional*
/// public methods used by ModelManager's per-model download/verify/unload UI;
/// they're not part of the `LLMEngine` protocol.
/// Chat-template variables passed on every generation.
///
/// Qwen 3.5 is a hybrid reasoning model: its chat template opens a `<think>`
/// block unless `enable_thinking` is explicitly false, and the model then emits
/// its reasoning ahead of the answer. That wrecks every pass we run — the
/// formatting passes would ship "Thinking Process: 1. Analyze the request…"
/// straight into the user's document, and the pass validators would (correctly)
/// reject it and fall back to the raw transcript every single time.
///
/// Setting it false makes the template prefill an empty think block, so the
/// model starts on the answer. Templates that never mention `enable_thinking`
/// — Gemma 4's, Llama's — ignore the key, so this is safe to send to every
/// model rather than special-casing by id. Verified against both families.
private let chatTemplateContext: [String: any Sendable] = ["enable_thinking": false]

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
    /// Reused prefill state for the Chat window. Dropped whenever the loaded
    /// model changes — cached keys and values mean nothing against different
    /// weights.
    @ObservationIgnored let chatPromptCache = ChatPromptCache()

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

    /// In-flight load, keyed by model id, so two callers racing for the same
    /// model share one load instead of doing two.
    ///
    /// This became reachable when Chat landed: `AppState.preloadModels()` fires
    /// a load at launch, and opening the Chat window immediately afterwards
    /// fires another through `ensureReady()`. Both saw `container == nil`, both
    /// loaded, and the machine briefly held two copies of a multi-gigabyte
    /// model — on a 16 GB Mac that is the difference between working and
    /// swapping.
    @ObservationIgnored private var loadInFlight: (id: String, task: Task<Void, Error>)?

    func ensureLoaded(modelID: String, progress: (@Sendable @MainActor (Double) -> Void)? = nil) async throws {
        if currentModelID == modelID, container != nil { return }
        if let inFlight = loadInFlight, inFlight.id == modelID {
            return try await inFlight.task.value
        }
        let task = Task<Void, Error> { [weak self] in
            try await self?.performLoad(modelID: modelID, progress: progress)
        }
        loadInFlight = (modelID, task)
        defer { if loadInFlight?.id == modelID { loadInFlight = nil } }
        try await task.value
    }

    private func performLoad(modelID: String, progress: (@Sendable @MainActor (Double) -> Void)? = nil) async throws {
        if currentModelID == modelID, container != nil { return }
        chatPromptCache.reset()
        container = nil
        currentModelID = nil
        isLoading = true
        defer { isLoading = false }

        // Vision-capable models load through the VLM factory instead of the LLM
        // one, so the single resident container can serve both the text passes
        // and window-vision reads. Measured on Gemma 4 12B: 41 MB more resident
        // than the text-only load (its "vision tower" is a thin projection, not
        // a separate encoder), text-pass output byte-identical, so there's no
        // reason to hold two containers or to swap models per task.
        let wantsVision = ModelCatalog.llm(id: modelID)?.visionCapable ?? false

        // The Hub-backed path, used only when the weights aren't already here.
        func loadFromHub() async throws -> ModelContainer {
            let progressHandler: @Sendable (Progress) -> Void = { p in
                let fraction = p.fractionCompleted
                Task { @MainActor in progress?(fraction) }
            }
            if wantsVision {
                return try await VLMModelFactory.shared.loadContainer(
                    from: HubDownloader(downloadBase: ModelStorage.llmRoot()),
                    using: HubTokenizerLoader(),
                    configuration: ModelConfiguration(id: modelID),
                    progressHandler: progressHandler
                )
            }
            return try await LLMModelFactory.shared.loadContainer(
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

        func loadFromDisk() async throws -> ModelContainer {
            if wantsVision {
                return try await VLMModelFactory.shared.loadContainer(
                    from: localDirectory, using: HubTokenizerLoader())
            }
            return try await LLMModelFactory.shared.loadContainer(
                from: localDirectory, using: HubTokenizerLoader())
        }

        let loaded: ModelContainer
        if isDownloaded {
            do {
                loaded = try await loadFromDisk()
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
        chatPromptCache.reset()
        container = nil
        currentModelID = nil
    }

    /// `LLMEngine` protocol method — drops whatever's currently loaded.
    func unload() {
        chatPromptCache.reset()
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

    /// True when the *currently resident* model can accept an image. Both
    /// halves matter: the catalog says the selected model is vision-capable,
    /// and a container is actually loaded — this never triggers a model load,
    /// because the caller is on the dictation hot path and a cold load would
    /// cost far more than the vision context is worth. No model resident yet
    /// (first dictation after launch, before the bootstrap preload lands) just
    /// means no vision that run.
    var canReadImages: Bool {
        guard let id = modelID ?? currentModelID else { return false }
        return (ModelCatalog.llm(id: id)?.visionCapable ?? false)
            && isLoaded(modelID: id)
    }

    /// Reads an image with the resident model and returns its raw reply.
    ///
    /// Runs at `.background` priority deliberately. `ModelContainer.perform`
    /// serialises, so a vision read still in flight when the user stops talking
    /// would otherwise *delay* the formatting pass instead of overlapping it.
    /// At `.background` an arriving dictation pass cancels this at the next
    /// token and the caller simply gets no terms — the same graceful
    /// degradation every other failure path here already has.
    ///
    /// Callers own the prompts and the parsing; this is just the transport.
    func readImage(
        _ image: CGImage,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        guard let container else {
            throw NSError(domain: "Dictator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No MLX model is loaded, so there's nothing to read the image with."
            ])
        }
        // Re-check the *resident* model here, not the selected one. The caller
        // decided to attempt vision when the read was kicked off, which for a
        // dictation is one recording earlier; the user can switch models in
        // Settings in between, and nothing unloads the old container until the
        // next pass swaps it. Handing an image to a text-only container does
        // not fail — `LLMUserInputProcessor` silently drops images and returns
        // the text — so the model would be asked to read a screenshot that
        // isn't there and would happily invent one. Fail loudly instead; the
        // caller turns this into "no terms this run".
        guard let resident = currentModelID,
              ModelCatalog.llm(id: resident)?.visionCapable == true else {
            throw NSError(domain: "Dictator", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The loaded model can't read images."
            ])
        }
        let ciImage = CIImage(cgImage: image)
        return try await LLMScheduler.shared.run(.background) {
            try await container.perform { (ctx: ModelContext) -> String in
                let userInput = UserInput(
                    chat: [
                        .system(systemPrompt),
                        .user(userPrompt, images: [.ciImage(ciImage)]),
                    ],
                    additionalContext: chatTemplateContext
                )
                let lmInput = try await ctx.processor.prepare(input: userInput)
                let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0)
                let result = try MLXLMCommon.generate(
                    input: lmInput, parameters: params, context: ctx,
                    didGenerate: { (_: [Int]) in Task.isCancelled ? .stop : .more }
                )
                return LLMTextUtilities.clean(result.output)
            }
        }
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
            ], additionalContext: chatTemplateContext)
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
    func complete(system: String, user: String, maxTokens: Int, temperature: Double = 0) async throws -> String {
        try await completeReportingUsage(system: system, user: user, maxTokens: maxTokens,
                                         temperature: temperature).text
    }

    /// The real implementation, plus the token counts MLX already hands back.
    /// `complete` throws them away (usage is recorded here either way); the LLM
    /// socket server keeps them, because the process on the other end of the
    /// socket can't see `UsageStatsStore`.
    func completeReportingUsage(system: String, user: String, maxTokens: Int,
                                temperature: Double = 0) async throws -> LLMCompletionResult {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }
        let cap = max(1, maxTokens)
        // Greedy (topP 1.0) at temperature 0, which is every dictation caller;
        // a non-zero temperature also opens topP up to 0.95, matching what
        // `assist` uses — sampling at full topP with a warm temperature is the
        // combination MLX's own examples pair.
        let temp = Float(max(0, temperature))
        let topP: Float = temp > 0 ? 0.95 : 1.0
        let generated = try await container.perform { (ctx: ModelContext) -> (output: String, inTokens: Int, outTokens: Int) in
            let userInput = UserInput(chat: [
                .system(system),
                .user(user)
            ], additionalContext: chatTemplateContext)
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: cap, temperature: temp, topP: topP)
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
        screenImage: CGImage? = nil,
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

        // The screenshot, when this model can read one. Attaching it to the
        // current user message means the model answers from the window itself
        // rather than from a text briefing someone wrote about the window —
        // no summarisation loss, and no separate describe-the-screen inference
        // before the answer can start.
        //
        // Same re-check as `readImage`, and for the same reason: `ensureReady()`
        // above may have just swapped in a different model from the one that
        // was resident when the capture was kicked off. Attaching to a
        // text-only container would silently drop the image and leave the
        // "[SCREEN] a screenshot is attached" line asking the model to describe
        // something it cannot see — an invitation to invent. Dropping the whole
        // block degrades to a normal, screenless assistant turn.
        let residentCanSee = currentModelID
            .flatMap { ModelCatalog.llm(id: $0)?.visionCapable } ?? false
        let screenCIImage = residentCanSee ? screenImage.map { CIImage(cgImage: $0) } : nil
        if screenImage != nil && !residentCanSee {
            MicLog.log("Assistant: dropped the screenshot — the loaded model can't read images.")
        }

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
            if let screenCIImage {
                messages.append(.user(
                    """
                    [SCREEN] A screenshot of the window the user is looking at is attached.                     Use it to answer. Read any text in it exactly as shown.
                    """,
                    images: [.ciImage(screenCIImage)]
                ))
            }
            messages.append(.user(currentUserText))

            let userInput = UserInput(chat: messages, additionalContext: chatTemplateContext)
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
            ], additionalContext: chatTemplateContext)
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

// MARK: - Chat

/// Streaming, tool-calling chat rounds for the Chat window.
///
/// `MLXLLMService` conforms; `AppleFoundationLLMService` deliberately does not
/// (see `LLMChatStreaming`).
extension MLXLLMService: LLMChatStreaming {
    /// True when the *currently selected* model is one we've measured as able
    /// to run a chat thread and an agent loop. Unlike `canReadImages` this does
    /// not require the model to be resident: opening the Chat window is allowed
    /// to trigger a load, because the user explicitly asked for it and is
    /// looking at a window that can show progress. The dictation hot path is
    /// the only place a cold load is unaffordable.
    var canChat: Bool {
        guard let id = modelID ?? currentModelID else { return false }
        return ModelCatalog.llm(id: id)?.chatCapable ?? false
    }

    func streamChatRound(
        messages: [ChatWireMessage],
        tools: [ToolSpec],
        maxTokens: Int,
        cacheOwner: String,
        onDelta: @MainActor @escaping (ChatStreamDelta) -> Void
    ) async throws -> ChatRoundResult {
        try await ensureReady()
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "LLM not loaded"
            ])
        }

        // Rendered outside `perform`: `[String: any Sendable]` crosses the
        // @Sendable boundary, and building it here keeps the closure small.
        let wire = messages.map(\.templateMessage)
        let toolSpecs: [ToolSpec]? = tools.isEmpty ? nil : tools

        let cache = chatPromptCache

        // Deltas travel on an AsyncStream rather than a per-chunk hop to the
        // main actor. Generation runs inside `perform`, off-main; a
        // `Task { @MainActor in … }` per token would deliver *unordered*, which
        // in a chat window means visibly scrambled text. A stream's
        // continuation preserves order.
        let (stream, continuation) = AsyncStream<ChatStreamDelta>.makeStream()

        // Run at .background so a dictation hotkey preempts this at the next
        // token (LLMScheduler cancels, MLX stops, the caller gets .preempted
        // and re-runs the round). Chat must never make someone wait to dictate.
        let work = Task { @MainActor in
            defer { continuation.finish() }
            return try await LLMScheduler.shared.run(.background) {
                // `Self.generateRound` is `nonisolated`, which is the whole
                // point: see its own comment. Do not inline it back here.
                try await Self.generateRound(
                    container: container,
                    messages: wire,
                    tools: toolSpecs,
                    maxTokens: maxTokens,
                    cache: cache,
                    cacheOwner: cacheOwner,
                    continuation: continuation
                )
            }
        }

        // Drain on the main actor, in order, while generation runs.
        for await delta in stream {
            onDelta(delta)
        }

        // `work.value` is not cancellation-aware on its own. Without this
        // handler, Stop (or closing the window) would leave the generation
        // running to completion while still holding the scheduler's single
        // background slot — so the next message failed with "already busy"
        // several seconds later, for no reason the user could see.
        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        UsageStatsStore.shared.recordLLMTokens(
            in: result.promptTokens, out: result.completionTokens)
        return result
    }

    /// The actual generation, deliberately `nonisolated`.
    ///
    /// **This must not run on the main actor.** `ModelContainer.perform` is
    /// backed by `SerialAccessContainer.read`, which awaits the closure
    /// *without hopping executors* — so the closure runs wherever the caller
    /// is. Called from the `@MainActor` body the scheduler requires, that put
    /// prompt tokenization and the entire token loop on the main thread, and
    /// the window froze for the length of every reply. A `nonisolated async`
    /// method called from the main actor runs on the cooperative pool instead,
    /// which is all it takes.
    ///
    /// Chunks travel out through `continuation` rather than a callback, so
    /// nothing here needs main-actor access at all.
    private nonisolated static func generateRound(
        container: ModelContainer,
        messages: [[String: any Sendable]],
        tools: [ToolSpec]?,
        maxTokens: Int,
        cache: ChatPromptCache,
        cacheOwner: String,
        continuation: AsyncStream<ChatStreamDelta>.Continuation
    ) async throws -> ChatRoundResult {
        try await container.perform { (ctx: ModelContext) -> ChatRoundResult in
            let input = UserInput(
                messages: messages,
                tools: tools,
                additionalContext: chatTemplateContext
            )
            let lmInput = try await ctx.processor.prepare(input: input)
            let params = GenerateParameters(
                maxTokens: maxTokens, temperature: 0.4, topP: 0.95)

            // Reuse whatever of this prompt is already prefilled. Safe to fall
            // back from at any point: a miss just prefills the lot, which is
            // what every round did before this existed.
            let promptTokens = lmInput.text.tokens.asArray(Int.self)
            let prepared = try cache.prepare(
                promptTokens: promptTokens, owner: cacheOwner,
                model: ctx.model, parameters: params)
            let seed = LMInput(tokens: MLXArray([promptTokens[promptTokens.count - 1]]))
            let iterator = try TokenIterator(
                input: seed, model: ctx.model, cache: prepared.cache, parameters: params)
            let (stream, _) = MLXLMCommon.generateTask(
                promptTokenCount: prepared.prefilled + 1,
                modelConfiguration: ctx.configuration,
                tokenizer: ctx.tokenizer,
                iterator: iterator,
                tools: tools)

            var text = ""
            var calls: [ChatWireToolCall] = []
            var completionTokens = 0
            var hitLimit = false
            for await item in stream {
                if Task.isCancelled { break }
                switch item {
                case .chunk(let piece):
                    text += piece
                    continuation.yield(.chunk(piece))
                case .toolCall(let call):
                    let wireCall = ChatWireToolCall(
                        name: call.function.name,
                        arguments: .object(
                            call.function.arguments.mapValues(MCPJSON.from(jsonValue:)))
                    )
                    calls.append(wireCall)
                    continuation.yield(.toolCall(wireCall))
                case .info(let info):
                    completionTokens = info.generationTokenCount
                    hitLimit = info.stopReason == .length
                }
            }
            return ChatRoundResult(
                text: LLMTextUtilities.cleanChatReply(text),
                toolCalls: calls,
                promptTokens: promptTokens.count,
                completionTokens: completionTokens,
                hitTokenLimit: hitLimit
            )
        }
    }
}
