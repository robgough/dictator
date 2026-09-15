import Foundation

/// One entry in a chat thread.
///
/// Models the four things that can appear in a transcript, not the four
/// chat-template roles — a tool *call* and its *result* are separate entries
/// because the UI shows them separately (a call can be pending approval, or
/// denied, long before there's a result), even though they collapse back into
/// two template messages when the thread is re-rendered for the model.
struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user
        case assistant
        /// A tool the model asked for, plus what came back.
        case tool
        /// Something went wrong for this turn. Kept in the transcript rather
        /// than shown as a transient banner, so a thread reopened tomorrow
        /// still explains its own gap.
        case failure
    }

    let id: UUID
    var kind: Kind
    var text: String
    let timestamp: Date

    // MARK: Tool entries

    var toolCall: ChatWireToolCall?
    /// nil while the call is pending or awaiting approval.
    var toolResult: String?
    var toolFailed: Bool = false
    /// Set when the user declined the call. The model is told, so it can try
    /// something else rather than silently getting nothing.
    var toolDenied: Bool = false
    /// Which MCP server (or `nil` for a built-in tool) ran this.
    var serverName: String?
    /// A file this tool call produced, shown in the transcript as something the
    /// user can read and act on rather than a path in a sentence.
    var producedFile: ProducedFile?

    // MARK: Assistant-mode entries
    //
    // Set on messages that came in through the Assistant hotkey rather than the
    // chat window. All optional, all defaulted: a chat message simply leaves
    // them nil, and the synthesised `Codable` reads threads written before
    // Assistant Mode moved into this store.

    /// The text that was selected in the other app when the user spoke. On the
    /// *user* message, because it's part of what was asked, not of the answer.
    var selection: String?
    /// What the assistant read to answer — the text around the cursor, and what
    /// the vision pass saw. On the user message for the same reason.
    var context: CapturedContextInfo?
    /// How the model classified its own reply (REPLACE / DRAFT). On the
    /// assistant message.
    var deliveryMode: AssistantMode?
    /// What actually happened to the reply — "Replaced selection", "Copied to
    /// clipboard". The model's classification is an intent; this is the
    /// outcome, and they differ whenever the paste couldn't land.
    var delivery: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        timestamp: Date = Date(),
        toolCall: ChatWireToolCall? = nil,
        toolResult: String? = nil,
        toolFailed: Bool = false,
        toolDenied: Bool = false,
        serverName: String? = nil,
        producedFile: ProducedFile? = nil,
        selection: String? = nil,
        context: CapturedContextInfo? = nil,
        deliveryMode: AssistantMode? = nil,
        delivery: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.toolCall = toolCall
        self.toolResult = toolResult
        self.toolFailed = toolFailed
        self.toolDenied = toolDenied
        self.serverName = serverName
        self.producedFile = producedFile
        self.selection = selection
        self.context = context
        self.deliveryMode = deliveryMode
        self.delivery = delivery
    }
}

/// A file the assistant wrote.
///
/// The path is stored, not the contents: the file is the real artefact, it
/// lives in the user's own folder, and they may well edit it after the fact —
/// so the transcript reads it back when it renders rather than keeping a stale
/// copy of what was written.
struct ProducedFile: Codable, Hashable, Sendable {
    var name: String
    var path: String
    var byteCount: Int

    var url: URL { URL(fileURLWithPath: path) }
    var stillExists: Bool { FileManager.default.fileExists(atPath: path) }

    var fileExtension: String { url.pathExtension.lowercased() }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// A saved conversation with the local model, from either way in.
///
/// Assistant Mode and the chat window are the same thing with different entry
/// points: a multi-turn conversation with whichever model is loaded. They used
/// to be two stores, two models and two windows, which meant an assistant reply
/// that *almost* worked was a dead end — the only way to pick it up with tools
/// was to retype it into the chat window. One thread type makes that a button.
///
/// What stays separate is the *call path*, deliberately. Assistant Mode is one
/// shot at `LLMScheduler.interactive` with a person holding a hotkey waiting for
/// text to land at their cursor; chat is up to eight rounds of tool dispatch at
/// `.background`. Those cannot be the same code, and trying would make the
/// assistant slow to save a file that isn't very large.
struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    /// Which way in this thread started. Shown in the sidebar, because "the one
    /// I dictated at in Mail" is how people find a thread again.
    ///
    /// It records the *origin*, not the current mode: continuing an assistant
    /// thread in the chat window leaves it `.assistant` forever. Changing it
    /// would lose the only fact the icon is there to tell you.
    enum Origin: String, Codable, Sendable {
        case chat
        case assistant
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var origin: Origin
    var messages: [ChatMessage]
    /// Model this thread has been talking to. Shown in the sidebar, and used to
    /// warn when the user switches models mid-thread.
    var modelID: String?
    /// User-set title. When nil the first user message stands in.
    var customTitle: String?
    /// Name of this chat's folder under `<synced>/Chat Files/`, assigned the
    /// first time it produces a file. Stored rather than derived because the
    /// title can change and the folder must not — every path already written
    /// into the transcript points inside it.
    var filesFolderName: String?
    /// A folder the user pointed this chat at — their project, their notes,
    /// wherever the work actually lives. When set it replaces the chat's own
    /// folder as the working directory.
    ///
    /// Crucially this is *theirs*, not ours: deleting the chat must never
    /// delete it, which is the one place the two cases must not be treated
    /// alike.
    var workingDirectoryPath: String?
    /// Set once the oldest turns have been summarised to fit the context
    /// window. The turns themselves stay in `messages` — the transcript keeps
    /// showing the whole conversation, and only the model's payload is
    /// shortened. Assistant Mode has always done this; chat threads inherit it.
    var compaction: ConversationCompaction?
    /// Set when an assistant thread is opened in the chat window, which exempts
    /// it from the 14-day sweep that assistant threads otherwise get.
    ///
    /// The sweep exists because a dictated one-liner that pasted into Mail is
    /// not a document. But the moment someone opens one in the chat window they
    /// have said otherwise, and deleting it a fortnight later would be a bug.
    var promoted: Bool = false

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        origin: Origin = .chat,
        messages: [ChatMessage] = [],
        updatedAt: Date? = nil,
        modelID: String? = nil,
        customTitle: String? = nil,
        promoted: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.origin = origin
        self.messages = messages
        self.modelID = modelID
        self.customTitle = customTitle
        self.promoted = promoted
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard let first = messages.first(where: { $0.kind == .user })?.text,
              !first.isEmpty
        else { return "New chat" }
        // One line, trimmed to something that fits a sidebar row.
        let line = first
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? first
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    var isEmpty: Bool { messages.isEmpty }

    var lastAssistantReply: String? {
        messages.last(where: { $0.kind == .assistant })?.text
    }

    mutating func append(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }

    mutating func update(_ message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index] = message
        updatedAt = Date()
    }
}

// MARK: - Feeding the assistant call

extension ChatThread {
    /// The thread as the turn pairs `LLMEngine.assist` wants.
    ///
    /// `ConversationTurn` stays as the shape the *prompt* is built from, while
    /// `ChatMessage` is the shape the transcript is stored in — the same split
    /// as `ChatWireMessage` on the chat side. Keeping them apart is what let
    /// Assistant Mode move into this store without touching either engine's
    /// `assist` implementation.
    ///
    /// Tool messages are skipped. A thread that has been continued in the chat
    /// window can contain them, and there is no way to express a tool round in
    /// this shape — but the assistant reply that *followed* the tool is in the
    /// list, so what the model said survives even though how it got there
    /// doesn't. The alternative, refusing to continue such a thread through the
    /// hotkey, would be worse.
    var assistantTurns: [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var pendingUser: ChatMessage?

        for message in messages {
            switch message.kind {
            case .user:
                pendingUser = message
            case .assistant:
                guard let user = pendingUser else { continue }
                pendingUser = nil
                turns.append(ConversationTurn(
                    id: message.id,
                    timestamp: message.timestamp,
                    instruction: user.text,
                    selection: user.selection,
                    mode: message.deliveryMode ?? .draft,
                    reply: message.text,
                    context: user.context
                ))
            case .tool, .failure:
                continue
            }
        }
        return turns
    }

    /// The turns the next assistant call will actually send, and the summary
    /// standing in for everything before them.
    ///
    /// Splitting on the compaction index here rather than at the call site is
    /// what stops the two entry points drifting: the chat window and the
    /// hotkey now ask the same question and get the same answer.
    var activeAssistantContext: (turns: [ConversationTurn], summary: String?) {
        let all = assistantTurns
        guard let compaction else { return (all, nil) }
        let dropped = min(compaction.upThroughTurnIndex + 1, all.count)
        return (Array(all.dropFirst(dropped)), compaction.summary)
    }

    /// What the next assistant call would cost, ignoring the instruction that
    /// hasn't been spoken yet. Drives the "approaching context limit" chip.
    var estimatedInputTokensForNextTurn: Int {
        let active = activeAssistantContext
        return ConversationContextBudget.estimateInputTokens(
            priorTurns: active.turns,
            summary: active.summary,
            selection: nil,
            instruction: ""
        )
    }

    @MainActor
    func isApproachingContextLimit(engine: any LLMEngine) -> Bool {
        estimatedInputTokensForNextTurn >= engine.assistantInputTokenBudget * 4 / 5
    }
}

extension ChatThread {
    /// Builds an `.assistant` thread from turn pairs.
    ///
    /// Shared by the `conversations.json` migration and the demo fixtures, so
    /// there is one definition of how a turn unfolds into messages rather than
    /// two that can drift. Timestamps come from the turns, so a thread built
    /// this way keeps its real chronology instead of collapsing to now.
    static func assistant(
        id: UUID = UUID(),
        turns: [ConversationTurn],
        compaction: ConversationCompaction? = nil
    ) -> ChatThread {
        var messages: [ChatMessage] = []
        for turn in turns {
            messages.append(ChatMessage(
                kind: .user,
                text: turn.instruction,
                timestamp: turn.timestamp,
                selection: turn.selection,
                context: turn.context))
            messages.append(ChatMessage(
                id: turn.id,
                kind: .assistant,
                text: turn.reply,
                timestamp: turn.timestamp,
                deliveryMode: turn.mode))
        }
        var thread = ChatThread(
            id: id,
            createdAt: turns.first?.timestamp ?? Date(),
            origin: .assistant,
            messages: messages,
            updatedAt: turns.last?.timestamp ?? Date())
        thread.compaction = compaction
        return thread
    }
}
