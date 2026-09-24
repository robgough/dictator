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
        /// Summarising the older part of the thread to fit the context window.
        case compacting
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

    /// Returns whether the message was accepted. The caller must not clear the
    /// composer on `false`: this refuses when a turn is still running, and
    /// clearing regardless made a refused message look like it had been sent
    /// and lost — the draft was gone and nothing appeared in the transcript.
    @discardableResult
    func send(_ text: String, attachments: [ChatAttachment] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attachment on its own is a message: dragging a PDF in and saying
        // nothing plainly means "read this".
        guard !trimmed.isEmpty || !attachments.isEmpty, let threadID else { return false }
        guard !isBusy else { return false }
        errorMessage = nil

        var thread = store.thread(id: threadID) ?? ChatThread(id: threadID)
        // On Apple the selected `llmModelID` is whichever MLX model the user
        // would use if they switched — recording it here would have a thread
        // claim it was written by a model that never saw it.
        thread.modelID = Self.currentModelIdentifier(settings())
        // Typing into a thread that arrived from the Assistant hotkey is the
        // user saying it's worth keeping, so it stops being swept at 14 days.
        // "Continue in Chat" says the same thing more explicitly; this covers
        // picking it out of the sidebar and carrying on.
        if thread.origin == .assistant { thread.promoted = true }
        thread.append(ChatMessage(kind: .user, text: trimmed, attachments: attachments))
        store.upsert(thread)

        turnTask = Task { await runTurn(threadID: threadID) }
        return true
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
            fail(threadID: threadID, "Chat needs a language model. Pick one in Settings → Models.")
            return
        }

        // Connecting MCP servers can take a second or two on first use, so do
        // it before the model starts thinking rather than between rounds.
        activity = .loadingModel
        var toolset = await availableTools()
        // One correction per turn, not per round.
        var nudgedAboutMissingFile = false
        var preemptions = 0

        // Once per turn, before any round. Compacting mid-turn would rewrite the
        // head of the prompt between rounds and throw away the prefill the
        // rounds of a turn exist to share.
        await compactIfNeeded(threadID: threadID, toolset: toolset)

        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { return }
            guard var thread = store.thread(id: threadID) else { return }

            let wire = Self.renderForModel(
                thread: thread,
                systemPrompt: Self.systemPrompt(
                    settings: settings(), toolset: toolset,
                    workingDirectoryDescription: workingDirectoryDescription(threadID: threadID)),
                budgetTokens: engineInputBudget(toolset: toolset),
                hotImageCap: hotImageCap()
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
            reply.speed = result.speed
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

            guard !result.toolCalls.isEmpty else {
                // The reply may have *said* it wrote a file without calling
                // anything. One correction, then the loop carries on.
                if !nudgedAboutMissingFile,
                   let missing = missingClaimedFile(in: reply.text, threadID: threadID) {
                    nudgedAboutMissingFile = true
                    recordMissingFileNotice(missing, threadID: threadID)
                    continue
                }
                return
            }

            // Run every call this round asked for. Both Qwen models routinely
            // emit two in one round when a question needs two tools, so this
            // is the normal path, not an edge case.
            for (call, superseded) in Self.resolvingDuplicateWrites(result.toolCalls) {
                if Task.isCancelled { return }
                if superseded {
                    recordSupersededCall(call, threadID: threadID)
                } else {
                    await runToolCall(call, toolset: &toolset, threadID: threadID)
                }
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
                        // Filtered here as well as in `cleanChatReply`, or a
                        // stray vision token flashes on screen for the rest of
                        // the reply before the commit tidies it away. A marker
                        // is a single token, so it arrives in one piece and
                        // can't be split across two chunks.
                        self.streamingText += LLMTextUtilities.stripModelMarkers(piece)
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

    /// Catches the model saying it wrote a file when it didn't.
    ///
    /// Reported from real use, and the most common way a turn ends badly: the
    /// reply says "I'm creating research_roadmap_simple.html now." and then
    /// stops. A round that ends in prose ends the turn, so nothing is written,
    /// nothing failed, and the user is left looking for a file that was never
    /// there. It is made *more* likely by the prompt telling the model to say
    /// what it's about to do before doing it — that instruction is worth
    /// keeping, so the loop has to close the gap instead.
    ///
    /// Deliberately a fact-check, not a phrasing rule. It only fires when a
    /// filename the model named, with an extension it is allowed to write,
    /// genuinely is not on disk — so "you could call it notes.md" and a file
    /// that really was written both pass silently. At most one nudge per turn:
    /// a model that ignores the correction is not going to be talked round by
    /// a second one, and the round cap is the backstop.
    private func missingClaimedFile(in text: String, threadID: UUID) -> String? {
        guard let thread = store.thread(id: threadID),
              let folder = try? ChatFiles.workingDirectory(for: thread)
        else { return nil }
        let claimed = FileClaimDetector.claimedFilenames(
            in: text, allowedExtensions: ChatFileWriter.allowedExtensions)
        for name in claimed {
            guard let url = ChatFileWriter.resolve(name: name, in: folder.url) else { continue }
            if FileManager.default.fileExists(atPath: url.path) { continue }
            return name
        }
        return nil
    }

    /// Tells the model, in the transcript, that the file isn't there.
    private func recordMissingFileNotice(_ name: String, threadID: UUID) {
        guard var thread = store.thread(id: threadID) else { return }
        thread.append(ChatMessage(
            kind: .notice,
            text: "Dictator: there is no file called “\(name)” in this conversation's folder. "
                + "You described writing it but never called the tool. Call create_file now "
                + "with the full contents, or tell the user it wasn't written."))
        store.upsert(thread)
    }

    /// Marks all but the last write to any one filename within a single round.
    ///
    /// A model that changes its mind mid-generation emits two `create_file`
    /// calls for the same name in one reply — measured: 6,350 bytes then
    /// 6,451 bytes of the same presentation. Both used to run, so the second
    /// hit the clash path and the user got a stray sibling file. Now the
    /// earlier ones are recorded as superseded and never touch the disk,
    /// which is also what the model meant.
    ///
    /// Order is preserved so the transcript still reads in the order the model
    /// wrote it. Pure function of the round's calls, so a preempted round that
    /// re-runs reaches the same answer.
    private static func resolvingDuplicateWrites(
        _ calls: [ChatWireToolCall]
    ) -> [(call: ChatWireToolCall, superseded: Bool)] {
        var lastIndexForTarget: [String: Int] = [:]
        for (index, call) in calls.enumerated() {
            guard let key = writeTarget(of: call) else { continue }
            lastIndexForTarget[key] = index
        }
        return calls.enumerated().map { index, call in
            guard let key = writeTarget(of: call) else { return (call, false) }
            return (call, lastIndexForTarget[key] != index)
        }
    }

    /// The filename a write-style call targets, or nil if it isn't one.
    private static func writeTarget(of call: ChatWireToolCall) -> String? {
        guard call.name == "create_file" || call.name == "update_file",
              let name = call.arguments["name"]?.stringValue,
              !name.isEmpty
        else { return nil }
        // create_file and update_file share a namespace deliberately: a round
        // that creates then updates the same name meant the update.
        return name.lowercased()
    }

    private func recordSupersededCall(_ call: ChatWireToolCall, threadID: UUID) {
        guard var thread = store.thread(id: threadID) else { return }
        let label = call.name == "update_file" ? "Update a file" : "Save a file"
        var entry = ChatMessage(kind: .tool, text: label, toolCall: call)
        entry.toolResult = "Nothing was written: a later call in the same reply wrote this "
            + "file instead. Only the last version was saved."
        entry.toolFailed = true
        thread.append(entry)
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
        if call.name == "update_plan" {
            output = runPlanUpdate(call: call, threadID: threadID)
            failed = output.hasPrefix("ERROR:")
        } else if call.name == "check_html" {
            // Its own branch rather than runFileTool's: loading a page is
            // asynchronous, and that function is deliberately synchronous so
            // the transcript entry can be filled in before it returns.
            output = await runHTMLCheck(call: call, threadID: threadID)
            failed = output.hasPrefix("ERROR:")
        } else if ["create_file", "update_file", "read_file", "list_files", "delete_file"]
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

    /// Replaces the thread's plan with what the model sent.
    ///
    /// Whole-list replacement rather than per-step edits: a 4-12B model that
    /// has to address an existing step by index or id gets it wrong, and a
    /// wrong tick is worse than a rewritten list. Sending the list back costs
    /// a few dozen tokens and is the thing these models do reliably.
    private func runPlanUpdate(call: ChatWireToolCall, threadID: UUID) -> String {
        guard var thread = store.thread(id: threadID) else {
            return "ERROR: this conversation no longer exists."
        }
        // Not `case .array` — measured across all five catalogue models, not
        // one of them sends the array the schema asks for. See
        // `PlanStepParsing`, which normalises what they actually send.
        let steps = PlanStepParsing.steps(
            from: call.arguments["steps"]?.jsonObject,
            fallbackText: call.arguments["text"]?.stringValue
        ).map { ChatThread.PlanStep(text: $0.text, done: $0.done) }
        guard !steps.isEmpty else {
            thread.plan = []
            store.upsert(thread)
            return "Plan cleared."
        }
        thread.plan = steps
        store.upsert(thread)
        let remaining = thread.plan.filter { !$0.done }.count
        return "Plan saved (\(thread.plan.count) steps, \(remaining) still to do). "
            + "It's shown to you on every message from now on, so don't repeat it back to the user."
    }

    /// Loads an HTML file this chat produced and reports what's wrong with it.
    ///
    /// Scoped the same way the file tools are: the name is resolved inside the
    /// chat's own folder, and the page is given read access to that folder and
    /// nothing else, so it can pull in the stylesheet and script the model
    /// wrote beside it.
    private func runHTMLCheck(call: ChatWireToolCall, threadID: UUID) async -> String {
        guard let thread = store.thread(id: threadID) else {
            return "ERROR: this conversation no longer exists."
        }
        let folder: (url: URL, folderName: String?)
        do {
            folder = try ChatFiles.workingDirectory(for: thread)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
        let name = call.arguments["name"]?.stringValue ?? ""
        guard let fileURL = ChatFileWriter.resolve(name: name, in: folder.url) else {
            return "ERROR: “\(name)” isn't a file in this chat's folder."
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "ERROR: there's no file called “\(name)” in this chat's folder. "
                + "Call list_files to see what's there."
        }
        guard fileURL.pathExtension.lowercased() == "html" else {
            return "ERROR: check_html only works on .html files."
        }
        return await HTMLChecker.check(fileURL: fileURL, readAccessTo: folder.url)
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
            if case .written(let url, let bytes) = outcome {
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

    /// What to record as the model behind a thread, and to compare against
    /// when one is reopened. Apple's engine has no catalogue entry, so it gets
    /// a reserved id that `ChatWindowController` renders by name.
    static let appleModelIdentifier = "apple.foundation"

    static func currentModelIdentifier(_ settings: DictatorSettings) -> String {
        settings.llmEngine == .apple ? appleModelIdentifier : settings.llmModelID
    }

    private func chatEngineService() -> (any LLMChatStreaming)? {
        switch settings().llmEngine {
        case .none:
            return nil
        case .apple:
            // Tool-free, but a real conversation — and the only way an Apple
            // user can reopen the assistant threads that used to live in the
            // menu bar. See the extension on `AppleFoundationLLMService`.
            return AppleFoundationLLMServiceHolder.shared
        case .mlx:
            let service = MLXLLMServiceHolder.shared
            service.modelID = settings().llmModelID
            guard service.canChat else { return nil }
            return service
        }
    }

    /// How many images this engine is willing to carry as pixels in one prompt.
    ///
    /// Zero when nothing on this Mac can see, which is also the pre-existing
    /// behaviour: every image renders as its stored description.
    private func hotImageCap() -> Int {
        switch settings().llmEngine {
        case .none:  return 0
        // Asks whether *Apple* can take an image, not whether anything on this
        // Mac can. `WindowVisionContext.canReadImages` is true when Apple can
        // see **or** a vision-capable MLX model happens to be resident, and that
        // conflation is a real bug on a release build: CI builds against the
        // macOS 26 SDK, so `FOUNDATION_MODELS_VISION` is off and this engine
        // silently renders images as text — while a Qwen 9B left loaded from
        // earlier would have said "yes, four images", and the prompt would
        // announce pictures the model never receives.
        //
        // Measured on macOS 27.0 GA: four 1024x600 images plus ~2,500 words fit
        // inside the 8K window and the model still identified the last of them.
        case .apple:
            guard AppleFoundationLLMService.canAttachImages,
                  WindowVisionContext.appleCanSee else { return 0 }
            // Two, not the four the window can physically hold. Four at the
            // nominal 1,200 tokens each is 4,800 — more than the whole 4,500
            // input budget — so the estimate would sit permanently above the
            // compaction trigger and never reach its target, summarising on
            // every single turn and still not fitting. Two leaves room for a
            // conversation around the pictures.
            return 2
        // One. Raw template dicts plus `images:` throw unless the image-bearing
        // message's `content` is the structured `[{"type":"image"},…]` list —
        // `ChatWireMessage.templateMessage` now emits that, verified against
        // Qwen 3.5 9B in `scratch/mlx-image-dicts-check` (with a tool
        // advertised, and with a text-only turn after the image).
        //
        // One rather than four because an image-bearing round cannot use
        // `ChatPromptCache` — it works on text tokens and drops the pixels — so
        // each such round pays a full prefill, unlike Apple where an image is
        // ~0.7s and there is no cache to lose.
        case .mlx:
            guard MLXLLMServiceHolder.shared.canReadImages else { return 0 }
            return 1
        }
    }

    /// Nominal cost of one image in the token estimate.
    ///
    /// The estimate elsewhere is characters over four, and an image contributes
    /// no characters — so without this, a thread whose window is being filled by
    /// pictures looks empty to the budget and compaction never fires on the thing
    /// actually filling it.
    ///
    /// Derived, not exact: four images sat alongside ~3,300 tokens of text inside
    /// Apple's 8,192, putting each below ~1,200. Erring high is the safe
    /// direction — it compacts sooner rather than overflowing.
    static let estimatedTokensPerImage = 1_200

    /// True when the selected engine can run the agent half of chat — tools,
    /// and therefore more than one round per turn.
    private func engineSupportsTools() -> Bool {
        settings().llmEngine == .mlx
    }

    private func availableTools() async -> ChatToolset {
        // Apple's engine gets an empty toolset, and that is load-bearing rather
        // than merely tidy: the tool list is advertised in the system prompt,
        // so handing it tools it cannot call would have it write plausible
        // calls as prose that nothing ever dispatches. Better no tools than
        // tools that silently do nothing.
        guard engineSupportsTools() else { return ChatToolset(builtIns: [], remote: []) }
        let builtIns = BuiltInChatTools.all(
            settings: settings(),
            canReadScreen: WindowVisionContext.canReadImages
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
        // Apple's window is 8192 (probed on macOS 27.0 GA) and an overflow
        // there throws mid-answer rather than degrading, so it gets its own,
        // much smaller budget — `renderForModel` then drops older turns sooner
        // instead of the round failing.
        let total: Int
        if settings().llmEngine == .apple {
            total = AppleFoundationLLMService.chatInputTokenBudget
        } else {
            // Not `assistantInputTokenBudget`: that reserves for Assistant
            // Mode's 8K reply cap, and this window's is 4K. Deriving it here
            // from the model's window gives the conversation back the
            // difference — a fifth of the usable history on a 32K model.
            let window = MLXLLMServiceHolder.shared.contextWindowTokens
            total = max(2_000, window - ConversationContextBudget.chatNonInputReservationTokens)
        }
        return max(1_500, total - toolset.estimatedPromptTokens)
    }

    /// Folds attached files into the message that brought them.
    ///
    /// Inlined rather than left for `read_file` to find. A model that has to
    /// decide to go and look at a file the user just dragged in will sometimes
    /// answer without doing so, and there's no recovering from that — the user
    /// has no way of knowing the file was ignored. The tools are still there
    /// for the overflow, and the truncation note points at them by name.
    ///
    /// The extracted text is taken from the attachment as stored, never
    /// re-derived: a round re-renders the whole thread, so deriving here would
    /// re-run a vision pass or a PDF parse on every round of every turn.
    /// Summarise the older part of the thread when it is close to filling the
    /// window, so `renderForModel`'s trim never has to drop anything.
    ///
    /// Hysteresis is the point: compact at 80% of budget and cut back to about
    /// 50%. Compacting to exactly the budget would compact again on the very
    /// next message, and each compaction rewrites the head of the prompt and
    /// costs a full re-prefill.
    ///
    /// Everything before the cut is covered by the summary, including the first
    /// message. Keeping that one verbatim *as well* was considered and dropped:
    /// it would say the same thing twice, and the summariser's whole job is to
    /// carry the intent forward.
    ///
    /// A failure here is not fatal. `renderForModel` still trims to the budget,
    /// so the turn proceeds with older messages dropped — worse than a summary,
    /// better than refusing to answer.
    private func compactIfNeeded(threadID: UUID, toolset: ChatToolset) async {
        guard let llm = currentSummariser(), let thread = store.thread(id: threadID) else { return }
        let budget = engineInputBudget(toolset: toolset)
        let prompt = Self.systemPrompt(
            settings: settings(), toolset: toolset,
            workingDirectoryDescription: workingDirectoryDescription(threadID: threadID))

        func estimate(_ candidate: ChatThread) -> Int {
            Self.estimatedTokens(Self.renderForModel(
                thread: candidate, systemPrompt: prompt,
                budgetTokens: .max, hotImageCap: hotImageCap()))
        }

        guard estimate(thread) > Int(Double(budget) * 0.8) else { return }

        // Where the last summary already reaches. Without this the second
        // compaction hands the summariser the prior summary *plus every turn
        // since the thread began* — the ones that summary already covers — so
        // its input grows with the thread forever. On Apple that overflows the
        // 8K window by about the third compaction, and from then on every turn
        // silently falls through to `trim`: history dropped rather than
        // summarised, with a stale summary still attached. Pipeline's assistant
        // path avoids this by slicing turns that are already post-cut.
        let start = thread.compaction?.upThroughMessageID
            .flatMap { id in thread.messages.firstIndex(where: { $0.id == id }) }
            .map { $0 + 1 } ?? 0

        // Walk backwards from the newest message, accumulating what the tail
        // costs, and cut at the last boundary that still fits the low-water
        // mark. The obvious version — step the cut forward and re-render the
        // tail each time — is O(n^2) string building on the main actor, which on
        // a long thread is a visible hitch before every single turn.
        //
        // The cut always lands immediately before a user message, so an
        // assistant message carrying `tool_calls` and the tool results that
        // answer it never end up on opposite sides of it. An orphaned tool
        // result makes Gemma 4's template raise, which is why `trim` is careful
        // about the same thing.
        let target = Int(Double(budget) * 0.5)
        var running = 0
        var cutIndex: Int? = nil
        for index in thread.messages.indices.reversed() where index > start {
            running += Self.estimatedTokens(for: thread.messages[index])
            // A cut at `index - 1` leaves the tail starting at `index`.
            guard thread.messages[index].kind == .user else { continue }
            if running > target { break }
            cutIndex = index - 1
        }
        // Nothing new to summarise: the only available cut is where the last one
        // already was. Leave it to `trim`.
        guard let cutIndex, cutIndex >= start else { return }

        // Only what the previous summary did not already cover.
        let turns = Self.summarisableTurns(
            from: Array(thread.messages[start...cutIndex]))
        guard !turns.isEmpty else { return }

        activity = .compacting
        do {
            // `.background`, like the rounds themselves. Summarising can run for
            // several seconds on a long thread, and the one thing the chat
            // window must never do is take the model away from a dictation the
            // user is in the middle of.
            let summary = try await LLMScheduler.shared.run(.background) {
                try await llm.summariseConversation(
                    turns: turns,
                    priorSummary: thread.compaction?.summary,
                    cancellation: { Task.isCancelled }
                )
            }
            if Task.isCancelled { return }
            // Re-read. `thread` was captured before an await that runs for
            // seconds, and upserting the stale copy would undo anything that
            // happened meanwhile — `send` is blocked by `isBusy`, but deleting
            // the thread from the sidebar is not, and writing this back would
            // resurrect it pointing at a folder that has already been removed.
            // Every other site in `runTurn` re-fetches for the same reason.
            guard var current = store.thread(id: threadID),
                  let cutID = current.messages.indices.contains(cutIndex)
                      ? current.messages[cutIndex].id : nil
            else { return }
            current.compaction = ConversationCompaction(
                summary: summary,
                // Not used on this path — the chat window cuts at a message.
                upThroughTurnIndex: -1,
                upThroughMessageID: cutID)
            store.upsert(current)
            NSLog("[Dictator] Chat: compacted %d message(s) into a summary.", cutIndex + 1)
        } catch {
            NSLog("[Dictator] Chat: couldn't summarise (%@) — the render will trim instead.",
                  error.localizedDescription)
        }
    }

    /// What one stored message costs the prompt, near enough to choose a cut by.
    ///
    /// Mirrors the wire estimate — four characters to the token plus a per-message
    /// overhead — and adds the nominal cost of any image that would ride as
    /// pixels. It deliberately does not re-render the message: this is called once
    /// per message while searching for a compaction boundary, and the point of
    /// the backwards walk is to avoid building those strings at all.
    static func estimatedTokens(for message: ChatMessage) -> Int {
        var chars = message.text.count + (message.selection?.count ?? 0)
        chars += message.toolResult?.count ?? 0
        // Tool-call arguments are rendered into the prompt too, and were being
        // counted as nothing — so a thread carrying six written-out HTML files
        // estimated far smaller than it really was, and compaction fired late
        // while the real prompt had already overrun the cache.
        //
        // The `contents` of a write is the exception, and is counted at its
        // elided size: `renderForModel` replaces it with a pointer for
        // everything before the last two exchanges, so on exactly the long
        // threads where this matters it is not in the prompt. Counting it in
        // full would swing the error the other way and compact a thread that
        // is comfortably inside the window.
        if case .object(let fields)? = message.toolCall?.arguments {
            let isWrite = message.toolCall?.name == "create_file"
                || message.toolCall?.name == "update_file"
            for (key, value) in fields {
                if isWrite && key == "contents" {
                    chars += 120
                } else {
                    chars += value.compactString.count + key.count + 4
                }
            }
        }
        for attachment in message.attachments {
            chars += attachment.text?.count ?? 0
        }
        let images = message.attachments.filter { $0.kind == .image }.count
        return chars / 4 + 8 + images * estimatedTokensPerImage
    }

    /// Pairs chat messages into turns for the summariser.
    ///
    /// Deliberately not `ChatThread.assistantTurns`, which pairs each user
    /// message with the *first* assistant message after it and then drops the
    /// rest. That is right for Assistant Mode, where a turn is one reply, and
    /// wrong here: a tool-using turn reads
    /// user → assistant("Let me check…") → tool → assistant(the actual answer),
    /// and the first-match rule summarises the preamble while discarding the
    /// answer. The last reply before the next user message is the answer.
    ///
    /// Tool calls and results are left out. A summary is about what was asked
    /// and concluded, and re-stating tool plumbing in it wastes the context the
    /// summary exists to reclaim.
    static func summarisableTurns(from messages: [ChatMessage]) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var pendingUser: ChatMessage?
        var lastReply: ChatMessage?

        func flush() {
            guard let user = pendingUser, let reply = lastReply else { return }
            turns.append(ConversationTurn(
                id: reply.id,
                timestamp: reply.timestamp,
                instruction: user.text,
                selection: user.selection,
                mode: reply.deliveryMode ?? .draft,
                reply: reply.text,
                context: user.context
            ))
            pendingUser = nil
            lastReply = nil
        }

        for message in messages {
            switch message.kind {
            case .user:
                flush()
                pendingUser = message
            case .assistant:
                if !message.text.isEmpty { lastReply = message }
            case .tool, .failure, .notice:
                // Not summarisable: a correction Dictator issued mid-turn is
                // about how the turn went, not about what was said.
                continue
            }
        }
        flush()
        return turns
    }

    /// The engine that writes the summary. Whichever engine is answering: both
    /// implement `summariseConversation`, and using the same one keeps the
    /// summary in the voice the rest of the thread is in.
    private func currentSummariser() -> (any LLMEngine)? {
        switch settings().llmEngine {
        case .none:  return nil
        case .apple: return AppleFoundationLLMServiceHolder.shared
        case .mlx:   return MLXLLMServiceHolder.shared
        }
    }

    /// Index before which tool results are elided: everything before the last
    /// *two* exchanges. A result from the question in progress is live context,
    /// and so, usually, is the one before it — that is where "now do X to what
    /// you just read" lives. Older than that and it is almost always dead.
    ///
    /// Returns 0 when there aren't two earlier user messages, which elides
    /// nothing.
    static func toolElisionCutoff(in messages: [ChatMessage]) -> Int {
        let userIndices = messages.indices.filter { messages[$0].kind == .user }
        guard userIndices.count >= 2 else { return 0 }
        return userIndices[userIndices.count - 2]
    }

    /// Cheap whole-thread estimate, used to decide whether eliding is worth its
    /// cost at all. Deliberately per-message arithmetic rather than a render:
    /// this runs on every turn.
    static func estimatedTokens(of messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimatedTokens(for: $1) }
    }

    /// Which image attachments this render sends as **pixels** rather than as the
    /// description written when they were dropped.
    ///
    /// Only images on the last two user messages are eligible, newest first, and
    /// only up to `cap`. Everything else renders as text — permanently, because a
    /// message that has fallen out of the window never comes back into it. That is
    /// what keeps the prompt a *growing prefix* rather than a shifting one, which
    /// is the single property `ChatPromptCache` depends on.
    ///
    /// The cap is per engine and is not a guess. Apple was measured holding four
    /// 1024x600 images alongside ~2,500 words inside its 8K window, still picking
    /// out the last one correctly, so its cap bounds a worst case rather than
    /// working around a limit. MLX's cap is 1 for an unrelated reason: an
    /// image-bearing round there cannot use the prompt cache at all (see
    /// `MLXLLMService.streamChatRound`), so each one costs a full prefill.
    ///
    /// A file the user has since deleted is skipped — it would fail to load at the
    /// engine and the stored description is the better answer anyway.
    static func hotImagePaths(in thread: ChatThread, cap: Int) -> Set<String> {
        guard cap > 0 else { return [] }
        var hot: [String] = []
        for message in thread.messages.filter({ $0.kind == .user }).suffix(2).reversed() {
            for attachment in message.attachments
            where attachment.kind == .image && attachment.stillExists {
                hot.append(attachment.path)
                if hot.count == cap { return Set(hot) }
            }
        }
        return Set(hot)
    }

    private static func withAttachments(
        _ text: String, _ attachments: [ChatAttachment], hot: Set<String> = []
    ) -> String {
        var out = text
        for attachment in attachments {
            let label: String
            switch attachment.kind {
            case .image: label = "Attached image"
            case .pdf: label = "Attached PDF"
            default: label = "Attached file"
            }

            // A hot image is in the prompt as pixels. It still needs naming — the
            // model has to be able to say "the second screenshot" — but it must not
            // also carry its description: that pays for the encode and then tells
            // the model what it says, which is the worst of both and invites it to
            // answer from the stale text instead of from what it can see.
            if attachment.kind == .image, hot.contains(attachment.path) {
                out += "\n\n[\(label): \(attachment.name) — shown to you directly below.]"
                continue
            }

            if let body = attachment.text, !body.isEmpty {
                let what = attachment.kind == .image
                    ? "what it shows" : "its contents"
                var block = "\n\n[\(label): \(attachment.name) — \(what) follow]\n\(body)"
                if attachment.truncated {
                    block += "\n[…truncated. The whole file is in your working directory — "
                        + "use read_file(\"\(attachment.name)\") if you need the rest.]"
                }
                out += block
            } else {
                let why = attachment.note ?? "its contents couldn't be read"
                out += "\n\n[\(label): \(attachment.name) — \(why). "
                    + "It is in your working directory. Say so rather than guessing at it.]"
            }
        }
        return out
    }

    /// Attaches the time to the newest user message.
    ///
    /// The clock lives on the message, not in the system prompt: it's genuinely
    /// a property of the message ("yesterday" means yesterday relative to when
    /// it was *asked*), and the system prompt is the head of the prompt, which
    /// a prompt cache needs byte-stable. A ticking clock at the front
    /// invalidates the prefix on every round.
    ///
    /// **After the text, and labelled.** It used to be a bare line prefixed to
    /// the message, and that reliably broke pronouns: "Give me the names of ten
    /// UK cities" → a list → "Give me that as a JSON object" returned
    /// `{day, date, time, timezone}`, because the nearest antecedent for "that"
    /// was the timestamp sitting directly above it. Moving it after the text
    /// helps; saying what it's for is what actually fixes it, because a small
    /// model shown an unexplained fact treats it as the subject.
    ///
    /// Measured over 5 models × 3 pronoun scenarios in
    /// `scratch/clock-anaphora-check`: prefixed 3/15, suffixed 11/15, suffixed
    /// and labelled 15/15 — with the clock questions still 15/15. Dropping the
    /// clock entirely fixes pronouns too and is not an option: without it every
    /// model states a confidently wrong date (May 2024, October 2026) rather
    /// than admitting it doesn't know.
    private static func withClock(_ text: String, at timestamp: Date) -> String {
        """
        \(text)

        [Ambient context, not part of the question above: right now it is \
        \(Self.clock.string(from: timestamp)). Ignore this unless the question \
        is about dates or times.]
        """
    }

    /// Replaces the `contents` of a stale `create_file` / `update_file` call
    /// with a pointer to the file.
    ///
    /// The call itself is kept — Gemma 4 renders a tool result only by scanning
    /// forward from the call that produced it, so dropping it would break every
    /// result after it. Only the payload goes.
    static func elidingWrittenContents(of call: ChatWireToolCall) -> ChatWireToolCall {
        guard call.name == "create_file" || call.name == "update_file",
              case .object(var fields) = call.arguments,
              case .string(let contents)? = fields["contents"],
              contents.count > 200
        else { return call }
        let name = fields["name"]?.stringValue ?? "the file"
        fields["contents"] = .string(
            "[\(contents.count) characters, elided to save room — “\(name)” is on disk; "
                + "call read_file to see it]")
        return ChatWireToolCall(id: call.id, name: call.name, arguments: .object(fields))
    }

    /// Trims from the front when the thread outgrows `budgetTokens`. Dropping
    /// oldest-first (rather than summarising, as Assistant Mode does) is the
    /// simple thing that can't fail: a summariser pass is another generation
    /// that can itself be preempted, and getting it wrong silently rewrites
    /// what the user said. The window keeps the system prompt and as much
    /// recent history as fits, and the UI says when something was dropped.
    ///
    /// A thread that Assistant Mode already compacted renders in full here and
    /// is trimmed to this budget instead — deliberately. The summary exists
    /// because the hotkey path had to fit a reply into an 8K reservation; the
    /// chat window has the whole window to play with, so it would be a poor
    /// trade to feed the model someone's paraphrase when the real turns fit.
    ///
    /// Flattens the stored transcript back into the message shape the chat
    /// template expects — which means folding each tool entry back into the
    /// assistant message that asked for it (see `ChatWireMessage` for why that
    /// matters).
    static func renderForModel(
        thread: ChatThread,
        systemPrompt: String,
        budgetTokens: Int = .max,
        hotImageCap: Int = 0
    ) -> [ChatWireMessage] {
        var wire: [ChatWireMessage] = [.system(systemPrompt)]
        let hotImages = Self.hotImagePaths(in: thread, cap: hotImageCap)

        // Everything the summary already covers is replaced by the summary. The
        // messages stay in `thread` — the transcript keeps showing the whole
        // conversation, and only the model's payload is shortened.
        var messages = thread.messages
        if let compaction = thread.compaction,
           let cutID = compaction.upThroughMessageID,
           let cutIndex = messages.firstIndex(where: { $0.id == cutID }) {
            messages = Array(messages.dropFirst(cutIndex + 1))
            wire.append(.user("""
                [Summary of the earlier part of this conversation, which has been \
                condensed to fit the model's context window:]
                \(compaction.summary)
                """))
        }

        // Tool *results* are stubbed only when the thread is actually big, and
        // only beyond the last two exchanges. Doing it unconditionally was
        // wrong in a way that loses work: "read notes.md" then "now change the
        // second paragraph" would find the file contents already gone, and a
        // small model will happily `update_file` from memory — overwriting the
        // user's file with reconstructed text. The stub is a last resort, not a
        // default.
        //
        // The assistant message carrying the `tool_calls` is left exactly where
        // it is. Gemma 4 renders a result only by scanning forward from one, so
        // removing the call would break everything after it.
        let elideToolResultsBefore = Self.estimatedTokens(of: messages) > budgetTokens / 2
            ? Self.toolElisionCutoff(in: messages)
            : 0

        let lastUserMessageID = messages.last(where: { $0.kind == .user })?.id

        for (index, message) in messages.enumerated() {
            switch message.kind {
            case .user:
                var content = message.text

                // A turn that came in through the Assistant hotkey was asked
                // *about* something — the text selected in another app at the
                // time. Without it the instruction is a dangling pronoun
                // ("tighten this"), and a thread continued in the chat window
                // would ask the model to work on something it can't see.
                if let selection = message.selection, !selection.isEmpty {
                    content = """
                        \(content)

                        [The text this was about:]
                        \(selection)
                        """
                }

                // Attachments are part of the question, so they go before the
                // clock and after the instruction — the model should read
                // "summarise this" then the thing, not the other way round.
                if !message.attachments.isEmpty {
                    content = Self.withAttachments(content, message.attachments, hot: hotImages)
                }

                if message.id == lastUserMessageID {
                    content = Self.withClock(content, at: message.timestamp)
                    // After the clock, for the same reason the clock sits after
                    // the question: whatever is nearest the end is what a small
                    // model treats as the subject, and the plan is the thing it
                    // should act on next. Re-rendered every turn from the
                    // thread rather than stored in the transcript, so it
                    // survives compaction and costs no round to consult.
                    if let plan = thread.planBlock {
                        content += "\n\n" + plan
                    }
                }
                var userMessage = ChatWireMessage(role: .user, content: content)
                userMessage.imagePaths = message.attachments
                    .filter { $0.kind == .image && hotImages.contains($0.path) }
                    .map(\.path)
                wire.append(userMessage)

            case .assistant:
                guard !message.text.isEmpty else { continue }
                wire.append(ChatWireMessage(role: .assistant, content: message.text))

            case .tool:
                guard let call = message.toolCall else { continue }
                // An assistant message carrying the call has to precede the
                // result. Gemma 4 renders the result *only* by scanning forward
                // from one; without it the model never sees what came back and
                // calls the same tool forever.
                //
                // The *arguments* are elided on the same schedule as the
                // result, because for a write the argument IS the file. A
                // thread that produced six HTML files was measured carrying
                // 33,000 characters of stale markup in every prompt, on every
                // round, for the rest of the conversation — which is what
                // pushed it past the prompt cache and turned each round into a
                // 22-second re-prefill. The file is on disk; read_file gets it
                // back when it's actually wanted.
                let renderedCall = index < elideToolResultsBefore
                    ? Self.elidingWrittenContents(of: call)
                    : call
                if var last = wire.last, last.role == .assistant {
                    last.toolCalls.append(renderedCall)
                    wire[wire.count - 1] = last
                } else {
                    wire.append(
                        ChatWireMessage(role: .assistant, content: "", toolCalls: [renderedCall]))
                }
                let result: String
                if index < elideToolResultsBefore {
                    result = "[result elided to fit the context window]"
                } else {
                    result = message.toolResult ?? "(no result)"
                }
                wire.append(
                    ChatWireMessage(
                        role: .tool,
                        content: result,
                        toolCallID: call.id,
                        toolName: call.name
                    ))

            case .notice:
                // Goes to the model as a user turn: there is no system role
                // available mid-conversation, and every chat template renders
                // a user message. Bracketed and self-identifying so it doesn't
                // read as something the person said.
                wire.append(ChatWireMessage(role: .user, content: "[\(message.text)]"))

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
                + message.imagePaths.count * estimatedTokensPerImage
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
        let head = system.map { [$0] } ?? []
        var body = Array(messages.dropFirst())

        // `body.count > 1`, not `!body.isEmpty`: the newest message is the
        // thing being answered, and dropping it to make room hands the model a
        // system prompt and no question. That was unreachable while the only
        // engine had a 32K-plus window; on Apple's 4.5K budget one ordinary PDF
        // gets there.
        while body.count > 1, estimatedTokens(head + body) > budget {
            body.removeFirst()
            // Having removed something, drop any tool results now left dangling.
            while let first = body.first, first.role == .tool, body.count > 1 {
                body.removeFirst()
            }
        }

        // Still over budget with one message left: that message is itself too
        // big. Cut it down rather than send nothing — the first pages of a long
        // document answer most questions asked about it, and the marker tells
        // both the model and (via the reply) the user what happened.
        if body.count == 1, var last = body.first, estimatedTokens(head + body) > budget {
            let marker = "\n\n[Cut off here — this message is longer than the model's context window.]"
            // The estimator counts 4 characters per token with 8 tokens of
            // per-message overhead; mirror it rather than guess.
            let images = last.imagePaths.count * estimatedTokensPerImage
            let allowance = max(400, (budget - estimatedTokens(head) - images - 8) * 4 - marker.count)
            if last.content.count > allowance {
                last.content = String(last.content.prefix(allowance)) + marker
                body = [last]
            }
        }

        var trimmed = head
        if body.count < messages.count - head.count {
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

            Do things in this order: say in one short line what you are about to do, \
            call the tool, then report what the tool result actually said. \
            Never say you have created, saved, updated or checked something \
            unless a tool result in this reply says so — if you only described \
            doing it, it did not happen. \
            Never end a reply having only said you are about to do something: \
            saying "I'm creating the file now" and then stopping means the user \
            gets nothing. Either call the tool in the same reply, or don't \
            mention it.
            """
        }

        // Worked examples rather than rules: at 4B-12B a model copies the
        // shape of an exchange far more reliably than it obeys an abstract
        // instruction, and the two failures these prevent — recreating a file
        // instead of updating it, and reporting a filename the tool didn't
        // return — were both measured against a description that already
        // said, in words, not to do them.
        if toolset.advertised.contains(where: { $0.name == "update_file" }) {
            prompt += """


            To change a file that already exists, read it and then update it. \
            create_file is only for a name that does not exist yet, and it will \
            refuse one that does. Always use the filename the tool result gives back.

            User: can you fix the heading in notes.md
            You: Reading notes.md first.
            → read_file(name: "notes.md")
            → update_file(name: "notes.md", contents: "<the whole file, with the heading fixed>")
            You: Updated notes.md — the heading is now "Q3 planning".
            """
        }

        if toolset.advertised.contains(where: { $0.name == "update_plan" }) {
            prompt += """


            When the user asks for something with several parts, call update_plan first \
            with the steps, then do the first one. Tick steps off as you finish them. \
            The plan comes back to you on every message, so it is how you remember what \
            you were doing — trust it over your own memory of earlier in the conversation.
            """
        }

        if toolset.advertised.contains(where: { $0.name == "check_html" }) {
            prompt += """


            After writing or changing an .html file, call check_html on it and fix what \
            it reports before you say it works. A page whose scripts throw nothing can \
            still be completely broken, so read what it says about CSS rules that match \
            nothing and about which elements are visible.
            """
        }

        prompt += """


        If they mention a company, product or person you do not recognise, it may well \
        be their own: check what you remember and search their journal before saying \
        you have not heard of it.
        """
        if toolset.advertised.contains(where: { $0.name == "search_meetings" }) {
            prompt += """


            Their meetings are recorded, transcribed and written up. When they ask about \
            a meeting, a call, what someone said, what was decided or who agreed to do \
            what, search their meetings and read the notes before answering; read the \
            transcript when the notes don't settle it, and say which meeting and roughly \
            when an answer came from.
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
