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
        producedFile: ProducedFile? = nil
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

/// A saved conversation with the local model.
struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    /// Where the thread came from.
    ///
    /// Only `.chat` is written today. The case exists from the first version
    /// because Assistant Mode's conversations are heading into this store —
    /// they're the same idea with a different entry point — and adding the
    /// discriminator later would mean migrating every persisted thread.
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

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        origin: Origin = .chat,
        messages: [ChatMessage] = [],
        modelID: String? = nil,
        customTitle: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.origin = origin
        self.messages = messages
        self.modelID = modelID
        self.customTitle = customTitle
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
