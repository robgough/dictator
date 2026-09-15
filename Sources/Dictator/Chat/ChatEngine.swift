import Foundation
import MLXLMCommon
import Observation
import SwiftUI

/// Drives one chat thread: prompt → generation → tool calls → generation, and
/// the approval and persistence around it.
///
/// The loop lives here rather than in `MLXLLMService` because it is
/// application policy, not engine capability: what tools exist, whether the
/// user has to approve one, how many rounds are too many, and what to do when
/// dictation takes the model away mid-reply. The engine only knows how to run
/// one round (`LLMChatStreaming.streamChatRound`).
@MainActor
@Observable
final class ChatEngine {
    /// What the composer and transcript render off.
    enum Activity: Equatable {
        case idle
        /// Model is loading (first message after launch, or after a switch).
        case loadingModel
        case thinking
        case streaming
        /// A tool is waiting on the user.
        case awaitingApproval
        case runningTool(String)
        /// Dictation took the model. We're waiting to pick the round back up.
        case pausedForDictation
    }

    /// A tool call the user has to decide about.
    struct PendingApproval: Identifiable {
        let id: String
        let tool: ChatTool
        let call: ChatWireToolCall
        let messageID: UUID
    }

    private(set) var activity: Activity = .idle
    /// Text of the reply currently streaming, and which message it belongs to.
    ///
    /// Held here rather than written into `ChatStore` per chunk: `upsert`
    /// reorders the thread list and fires Observation on every subscriber, so
    /// a per-token write re-rendered the whole sidebar for each token. The
    /// store gets one write when the round ends.
    private(set) var streamingMessageID: UUID?
    /// Raw accumulation, exactly as the model emitted it.
    private(set) var streamingText: String = ""

    /// What the transcript should actually show.
    ///
    /// The raw stream contains the model's reasoning — Gemma 4 12B opens every
    /// reply with a `<|channel>thought … <channel|>` span — and rendering it
    /// verbatim put the model's private notes on screen above each answer.
    /// Cleaning only the finished round result wasn't enough: the leak is
    /// visible the whole time the reply is arriving, which is most of when the
    /// user is looking at it.
    var visibleStreamingText: String {
        LLMTextUtilities.stripReasoningSpans(streamingText)
    }
    private(set) var pendingApproval: PendingApproval?
    /// Last error, shown above the composer. Cleared when the user sends again.
    private(set) var errorMessage: String?

    var threadID: UUID?

    /// How many generate→tool→generate rounds one user message may take. A
    /// model that keeps calling the same tool stops here rather than burning
    /// the battery until someone notices.
    /// How the assistant is told what time it is. Formatted from the user
    /// message's own timestamp, so it is fixed for the life of that turn.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm zzz"
        formatter.locale = Locale.current
        return formatter
    }()

    private static let maxRounds = 8
    /// How many times a *turn* may be re-run after being preempted. Counted
    /// per turn, not per round: a turn with several tool rounds would otherwise
    /// get this budget over and over, and each retry starts a fresh prefill
    /// that a dictation then has to queue behind.
    private static let maxPreemptionRetries = 4
    private static let replyTokenCap = 4096

    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<Bool, Never>?

    private let store = ChatStore.shared
    private let settings: () -> DictatorSettings

    init(settings: @escaping () -> DictatorSettings) {
        self.settings = settings
    }

    var isBusy: Bool { activity != .idle }

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let threadID else { return }
        guard !isBusy else { return }
        errorMessage = nil

        var thread = store.thread(id: threadID) ?? ChatThread(id: threadID)
        thread.modelID = settings().llmModelID
        thread.append(ChatMessage(kind: .user, text: trimmed))
        store.upsert(thread)

        turnTask = Task { await runTurn(threadID: threadID) }
    }

    /// Stops the current turn. The partial reply stays in the transcript —
    /// throwing away what the model already said would lose work the user can
    /// see and may want.
    func cancel() {
        turnTask?.cancel()
        turnTask = nil
        resolveApproval(false)
        // Cancelling the turn task unwinds our side, but the generation itself
        // lives in the scheduler's background job — tell it to stop too, or it
        // keeps burning the GPU and holding the slot after the user hit Stop.
        LLMScheduler.shared.cancelBackground()
        // Keep whatever streamed so far: the user stopped it, they can still
        // read it. Anything else throws away work they were looking at.
        commitStreamingText()
        activity = .idle
    }

    /// Writes an in-flight streamed reply into the store. Used when a turn ends
    /// without a clean round result — Stop, or a failure mid-stream.
    private func commitStreamingText() {
        guard let id = streamingMessageID, let threadID,
              var thread = store.thread(id: threadID),
              let index = thread.messages.firstIndex(where: { $0.id == id })
        else {
            streamingMessageID = nil
            streamingText = ""
            return
        }
        let text = LLMTextUtilities.cleanChatReply(streamingText)
        if text.isEmpty {
            thread.messages.remove(at: index)
        } else {
            thread.messages[index].text = text + "\n\n_(stopped)_"
        }
        store.upsert(thread)
        streamingMessageID = nil
        streamingText = ""
    }

    // MARK: - Approval

    func approve(always: Bool) {
        if always, let pending = pendingApproval, let serverID = pending.tool.serverID {
            guard let (_, bareName) = MCPRegistry.shared.resolve(namespacedName: pending.tool.name)
            else { return resolveApproval(true) }
            MCPRegistry.shared.autoApprove(toolName: bareName, serverID: serverID)
        }
        resolveApproval(true)
    }

    func deny() {
        resolveApproval(false)
    }

    private func resolveApproval(_ granted: Bool) {
        guard let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        pendingApproval = nil
        continuation.resume(returning: granted)
    }

    // MARK: - The loop

    private func runTurn(threadID: UUID) async {
        defer {
            activity = .idle
            turnTask = nil
        }

        guard let engine = chatEngineService() else {
            fail(threadID: threadID, "Chat needs an MLX model. Pick one in Settings → Models.")
            return
        }

        // Connecting MCP servers can take a second or two on first use, so do
        // it before the model starts thinking rather than between rounds.
        activity = .loadingModel
        var toolset = await availableTools()
        var preemptions = 0

        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { return }
            guard var thread = store.thread(id: threadID) else { return }

            let wire = Self.renderForModel(
                thread: thread,
                systemPrompt: Self.systemPrompt(
                    settings: settings(), toolset: toolset,
                    workingDirectoryDescription: workingDirectoryDescription(threadID: threadID)),
                budgetTokens: engineInputBudget(toolset: toolset)
            )

            // The assistant message this round streams into. Created up front
            // so tokens have somewhere to land as they arrive.
            var reply = ChatMessage(kind: .assistant, text: "")
            thread.append(reply)
            store.upsert(thread)
            activity = .thinking

            let result: ChatRoundResult
            do {
                result = try await runRoundWithRetries(
                    engine: engine,
                    messages: wire,
                    tools: toolset.specs,
                    replyID: reply.id,
                    cacheOwner: threadID.uuidString,
                    preemptions: &preemptions
                )
            } catch is CancellationError {
                commitStreamingText()
                return
            } catch {
                // Keep whatever streamed before it broke — the user was
                // reading it — and leave the failure note underneath.
                commitStreamingText()
                removeIfEmpty(reply.id, threadID: threadID)
                fail(threadID: threadID, error.localizedDescription)
                return
            }

            streamingMessageID = nil
            streamingText = ""
            guard var updated = store.thread(id: threadID) else { return }
            reply.text = result.text
            if result.hitTokenLimit {
                reply.text += "\n\n_(cut off — the reply hit the length limit.)_"
            }
            if reply.text.isEmpty && !result.toolCalls.isEmpty {
                // Went straight to a tool without saying anything. Drop the
                // empty bubble rather than render a blank one.
                updated.messages.removeAll(where: { $0.id == reply.id })
            } else {
                updated.update(reply)
            }
            store.upsert(updated)

            guard !result.toolCalls.isEmpty else { return }

            // Run every call this round asked for. Both Qwen models routinely
            // emit two in one round when a question needs two tools, so this
            // is the normal path, not an edge case.
            for call in result.toolCalls {
                if Task.isCancelled { return }
                await runToolCall(call, toolset: &toolset, threadID: threadID)
            }
        }

        fail(threadID: threadID,
             "Stopped after \(Self.maxRounds) rounds of tool calls without a final answer.")
    }

    /// Runs one round, re-running it when dictation preempts.
    ///
    /// This is the payoff for rendering the whole thread each round instead of
    /// keeping a KV cache: a preempted round has changed nothing, so it can
    /// simply be run again.
    ///
    /// Two things stop that from turning into a fight with the dictation the
    /// user is in the middle of. First, a retry waits for the pipeline to
    /// actually reach `.idle` — MLX's cancellation only lands inside the token
    /// loop, so re-entering while a dictation is still running its passes would
    /// start an *uncancellable prefill* that the next pass then queues behind,
    /// making dictation slower the more the user chats. Second, the budget is
    /// per turn, so a tool-heavy turn can't keep spending it.
    private func runRoundWithRetries(
        engine: any LLMChatStreaming,
        messages: [ChatWireMessage],
        tools: [ToolSpec],
        replyID: UUID,
        cacheOwner: String,
        preemptions: inout Int
    ) async throws -> ChatRoundResult {
        while true {
            do {
                activity = .thinking
                streamingMessageID = replyID
                streamingText = ""
                return try await engine.streamChatRound(
                    messages: messages,
                    tools: tools,
                    maxTokens: Self.replyTokenCap,
                    cacheOwner: cacheOwner
                ) { [weak self] delta in
                    guard let self else { return }
                    if case .chunk(let piece) = delta {
                        self.streamingText += piece
                        if self.activity != .streaming { self.activity = .streaming }
                    }
                }
            } catch let error as LLMSchedulerError {
                // .preempted: a dictation pass took the model.
                // .busy: Dictator Meetings holds the single background slot.
                // Both mean "later", not "failed".
                preemptions += 1
                guard preemptions <= Self.maxPreemptionRetries else { throw error }
                activity = .pausedForDictation
                try await waitUntilModelIsFree(wasBusy: {
                    if case .busy = error { return true } else { return false }
                }())
            }
        }
    }

    /// Waits for the local user to stop using the model.
    ///
    /// Polls rather than observes because both signals live in different places
    /// (`Pipeline.state` for dictation, `LLMScheduler.busy` for a Meetings job)
    /// and a coarse poll is entirely adequate for something measured in
    /// seconds. Bounded so a wedged pipeline can't hang the chat forever.
    private func waitUntilModelIsFree(wasBusy: Bool) async throws {
        // A Meetings final-notes pass can run for minutes, so give that longer
        // than a dictation, which is over in seconds.
        let deadline = Date().addingTimeInterval(wasBusy ? 120 : 20)
        while Date() < deadline {
            try Task.checkCancellation()
            let pipelineIdle = AppState.shared.pipeline.state == .idle
            if pipelineIdle && !LLMScheduler.shared.busy {
                // A beat of headroom so we don't re-enter between two passes of
                // the same dictation.
                try await Task.sleep(for: .milliseconds(400))
                if AppState.shared.pipeline.state == .idle { return }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func removeIfEmpty(_ messageID: UUID, threadID: UUID) {
        guard var thread = store.thread(id: threadID) else { return }
        thread.messages.removeAll(where: { $0.id == messageID && $0.text.isEmpty })
        store.upsert(thread)
    }

    // MARK: - Tool dispatch

    private func runToolCall(
        _ call: ChatWireToolCall, toolset: inout ChatToolset, threadID: UUID
    ) async {
        guard var thread = store.thread(id: threadID) else { return }

        guard let tool = toolset.tool(named: call.name) else {
            // The model invented a tool. Tell it so, in the transcript, so it
            // can correct itself on the next round.
            var entry = ChatMessage(kind: .tool, text: call.name, toolCall: call)
            entry.toolResult = "ERROR: there is no tool called “\(call.name)”."
            entry.toolFailed = true
            thread.append(entry)
            store.upsert(thread)
            return
        }

        var entry = ChatMessage(
            kind: .tool, text: tool.displayName, toolCall: call, serverName: tool.serverName)
        thread.append(entry)
        store.upsert(thread)

        if !tool.isSafeWithoutApproval {
            activity = .awaitingApproval
            let granted = await requestApproval(tool: tool, call: call, messageID: entry.id)
            if !granted {
                entry.toolDenied = true
                entry.toolResult = "The user declined this tool call. Continue without it, or suggest another way."
                updateEntry(entry, threadID: threadID)
                return
            }
        }

        activity = .runningTool(tool.displayName)
        let output: String
        var failed = false
        if ["create_file", "update_file", "read_file", "list_files", "delete_file"]
            .contains(call.name) {
            // Dispatched here rather than in BuiltInChatTools because the
            // transcript entry carries the resulting file, and only the loop
            // owns the transcript.
            output = runFileTool(call: call, entry: &entry, threadID: threadID)
            failed = output.hasPrefix("ERROR:")
        } else if call.name == ChatToolset.findToolsTool.name {
            // Handled here rather than in BuiltInChatTools because it mutates
            // the turn's tool list, which is state the loop owns.
            output = toolset.loadTools(matching: call.arguments["query"]?.stringValue ?? "")
        } else if tool.serverID != nil {
            do {
                let result = try await MCPRegistry.shared.callTool(
                    namespacedName: call.name, arguments: call.arguments)
                output = result.text.isEmpty ? "(the tool returned nothing)" : result.text
                failed = result.isError
            } catch is CancellationError {
                // The user pressed Stop. Leave the row showing what was asked
                // for rather than inventing a failure the server didn't have.
                entry.toolResult = "Stopped."
                entry.toolFailed = true
                updateEntry(entry, threadID: threadID)
                return
            } catch {
                output = "ERROR: \(error.localizedDescription)"
                failed = true
            }
        } else {
            output = await BuiltInChatTools.run(
                name: call.name,
                arguments: call.arguments,
                settings: settings(),
                readScreen: { await ChatScreenReader.read(question: call.arguments["question"]?.stringValue) }
            )
        }

        entry.toolResult = Self.truncateToolOutput(output)
        entry.toolFailed = failed
        updateEntry(entry, threadID: threadID)
    }

    /// The file tools, all scoped to this chat's own folder.
    ///
    /// Dispatched here rather than in `BuiltInChatTools` because they need the
    /// thread — its folder, and (for writes) the transcript entry that carries
    /// the resulting file card.
    private func runFileTool(
        call: ChatWireToolCall, entry: inout ChatMessage, threadID: UUID
    ) -> String {
        guard let thread = store.thread(id: threadID) else {
            return "ERROR: this conversation no longer exists."
        }
        let folder: (url: URL, folderName: String?)
        do {
            folder = try ChatFiles.workingDirectory(for: thread)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
        if let name = folder.folderName, thread.filesFolderName != name {
            var updated = thread
            updated.filesFolderName = name
            store.upsert(updated)
        }

        let name = call.arguments["name"]?.stringValue ?? ""
        let contents = call.arguments["contents"]?.stringValue ?? ""

        switch call.name {
        case "list_files":
            return ChatFileWriter.list(in: folder.url)

        case "read_file":
            return ChatFileWriter.read(name: name, in: folder.url)

        case "delete_file":
            return ChatFileWriter.delete(name: name, in: folder.url)

        case "create_file", "update_file":
            let outcome = call.name == "create_file"
                ? ChatFileWriter.write(name: name, contents: contents, in: folder.url)
                : ChatFileWriter.update(name: name, contents: contents, in: folder.url)
            if case .written(let url, let bytes, _) = outcome {
                // An updated file gets a card too — the user should see the
                // version that now exists, not the one from three messages ago.
                entry.producedFile = ProducedFile(
                    name: url.lastPathComponent, path: url.path, byteCount: bytes)
            }
            return outcome.modelDescription

        default:
            return "ERROR: \(call.name) isn't a file tool."
        }
    }

    private func updateEntry(_ entry: ChatMessage, threadID: UUID) {
        guard var thread = store.thread(id: threadID) else { return }
        thread.update(entry)
        store.upsert(thread)
    }

    private func requestApproval(
        tool: ChatTool, call: ChatWireToolCall, messageID: UUID
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = PendingApproval(
                id: call.id, tool: tool, call: call, messageID: messageID)
        }
    }

    /// A tool that returns a megabyte of JSON would blow the context window and
    /// take the thread down with it. Truncating loudly is better than failing.
    private static func truncateToolOutput(_ text: String, limit: Int = 8000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n\n…[truncated: the tool returned \(text.count) characters]"
    }

    // MARK: - Assembly

    private func chatEngineService() -> (any LLMChatStreaming)? {
        guard settings().llmEngine == .mlx else { return nil }
        let service = MLXLLMServiceHolder.shared
        service.modelID = settings().llmModelID
        guard service.canChat else { return nil }
        return service
    }

    private func availableTools() async -> ChatToolset {
        let service = MLXLLMServiceHolder.shared
        let builtIns = BuiltInChatTools.all(
            settings: settings(),
            canReadScreen: service.canReadImages
        )
        let remote = await MCPRegistry.shared.connectAll()
        return ChatToolset(builtIns: builtIns, remote: remote)
    }

    /// What's left for the conversation after the system prompt and the tool
    /// list have taken their share.
    ///
    /// The tool list is not small once MCP is in play, and it is re-sent every
    /// round. Ignoring it is how a thread that looks short overflows the
    /// model's window and starts producing nonsense — especially on Gemma 4
    /// 12B, whose 32K is the tightest in the catalog.
    /// Where the file tools will operate, phrased for the prompt. nil when the
    /// chat is using its own folder, which needs no explanation.
    private func workingDirectoryDescription(threadID: UUID) -> String? {
        guard let thread = store.thread(id: threadID),
              let path = thread.workingDirectoryPath
        else { return nil }
        return "the folder “\((path as NSString).abbreviatingWithTildeInPath)”"
    }

    private func engineInputBudget(toolset: ChatToolset) -> Int {
        let total = MLXLLMServiceHolder.shared.assistantInputTokenBudget
        return max(1_500, total - toolset.estimatedPromptTokens)
    }

    /// Flattens the stored transcript back into the message shape the chat
    /// template expects — which means folding each tool entry back into the
    /// assistant message that asked for it (see `ChatWireMessage` for why that
    /// matters).
    ///
    /// Trims from the front when the thread outgrows `budgetTokens`. Dropping
    /// oldest-first (rather than summarising, as Assistant Mode does) is the
    /// simple thing that can't fail: a summariser pass is another generation
    /// that can itself be preempted, and getting it wrong silently rewrites
    /// what the user said. The window keeps the system prompt and as much
    /// recent history as fits, and the UI says when something was dropped.
    static func renderForModel(
        thread: ChatThread,
        systemPrompt: String,
        budgetTokens: Int = .max
    ) -> [ChatWireMessage] {
        var wire: [ChatWireMessage] = [.system(systemPrompt)]
        let lastUserMessageID = thread.messages.last(where: { $0.kind == .user })?.id

        for message in thread.messages {
            switch message.kind {
            case .user:
                // The clock lives here, on the newest user message, not in the
                // system prompt. Two reasons, and the second is the important
                // one:
                //
                // 1. It is genuinely a property of the message — "yesterday"
                //    means yesterday relative to when it was *asked*, which is
                //    what the stored timestamp records.
                // 2. The system prompt is the head of the prompt, and a clock
                //    in it changes every minute. Anything that hopes to reuse a
                //    prefill — the whole point of a prompt cache — needs that
                //    head to be byte-stable. A ticking clock at the front
                //    invalidates the prefix on literally every round.
                if message.id == lastUserMessageID {
                    wire.append(.user("[Right now it is \(Self.clock.string(from: message.timestamp)).]\n\n\(message.text)"))
                } else {
                    wire.append(.user(message.text))
                }

            case .assistant:
                guard !message.text.isEmpty else { continue }
                wire.append(ChatWireMessage(role: .assistant, content: message.text))

            case .tool:
                guard let call = message.toolCall else { continue }
                // An assistant message carrying the call has to precede the
                // result. Gemma 4 renders the result *only* by scanning forward
                // from one; without it the model never sees what came back and
                // calls the same tool forever.
                if var last = wire.last, last.role == .assistant {
                    last.toolCalls.append(call)
                    wire[wire.count - 1] = last
                } else {
                    wire.append(
                        ChatWireMessage(role: .assistant, content: "", toolCalls: [call]))
                }
                wire.append(
                    ChatWireMessage(
                        role: .tool,
                        content: message.toolResult ?? "(no result)",
                        toolCallID: call.id,
                        toolName: call.name
                    ))

            case .failure:
                // Not sent to the model: it's a note to the user about a turn
                // that didn't happen, and replaying it as context would invite
                // the model to apologise for it.
                continue
            }
        }

        return trim(wire, toTokens: budgetTokens)
    }

    /// Rough chars/4 estimate, matching `ConversationContextBudget`.
    private static func estimatedTokens(_ messages: [ChatWireMessage]) -> Int {
        messages.reduce(0) { total, message in
            let argumentChars = message.toolCalls.reduce(0) {
                $0 + $1.name.count + $1.arguments.compactString.count
            }
            return total + (message.content.count + argumentChars) / 4 + 8
        }
    }

    /// Drops whole messages from the oldest end until the estimate fits.
    ///
    /// Never drops the system prompt, and never leaves a `tool` message whose
    /// preceding assistant `tool_calls` has gone — an orphaned tool result
    /// makes Gemma 4's template raise, and makes Qwen's render a response to
    /// nothing.
    private static func trim(_ messages: [ChatWireMessage], toTokens budget: Int) -> [ChatWireMessage] {
        guard budget != .max, estimatedTokens(messages) > budget else { return messages }
        let system = messages.first
        var body = Array(messages.dropFirst())

        while !body.isEmpty,
              estimatedTokens((system.map { [$0] } ?? []) + body) > budget {
            body.removeFirst()
            // Having removed something, drop any tool results now left dangling.
            while let first = body.first, first.role == .tool {
                body.removeFirst()
            }
        }

        var trimmed = system.map { [$0] } ?? []
        if !body.isEmpty {
            trimmed.append(
                .user("[Earlier messages in this conversation were dropped to fit the model's context window.]"))
        }
        trimmed.append(contentsOf: body)
        return trimmed
    }

    static func systemPrompt(
        settings: DictatorSettings, toolset: ChatToolset, workingDirectoryDescription: String? = nil
    ) -> String {
        var prompt = """
        You are Dictator's assistant, running entirely on \(NSFullUserName())'s Mac. \
        You are talking to them in a chat window.

        Answer in plain prose. Be direct and concise — they can ask for more. \
        Use markdown only when it genuinely helps (lists, code). \
        Never invent facts about the user, their files or their calendar: \
        if you need something you don't have, use a tool or say you don't know.
        """

        if let directory = workingDirectoryDescription {
            prompt += """


            The file tools work in \(directory). Paths are relative to it — \
            "notes.md" or "src/main.swift" — and nothing outside it is reachable.
            """
        }

        if !toolset.advertised.isEmpty {
            prompt += """


            You have tools. Call one only when it is the only way to get what you need, \
            and never to answer something you already know. \
            After a tool returns, answer the question in prose — do not call the same tool again.
            """
        }
        if toolset.isDeferred {
            prompt += "\n\n" + toolset.indexBlock
        }

        if settings.assistantMemoryEnabled,
           let memory = AssistantMemory.shared.promptBlock() {
            prompt += "\n\n\(memory)"
        }

        let persona = settings.assistantPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty {
            prompt += "\n\n\(persona)"
        }
        return prompt
    }

    private func fail(threadID: UUID, _ message: String) {
        errorMessage = message
        guard var thread = store.thread(id: threadID) else { return }
        thread.append(ChatMessage(kind: .failure, text: message))
        store.upsert(thread)
    }
}
