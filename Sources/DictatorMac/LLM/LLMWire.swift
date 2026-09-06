import Foundation

/// Where Dictator publishes its loaded-LLM socket, and how the two mac apps
/// frame messages over it.
///
/// Dictator (the menu-bar dictation app) listens; Dictator Meetings connects.
/// The point is that a Mac only ever holds ONE copy of a multi-GB checkpoint in
/// RAM: when Dictator is running with a model loaded, Meetings borrows it
/// instead of loading a second one. Meetings falls back to its own in-process
/// engine whenever the socket isn't there, isn't answering, or reports the
/// model isn't loaded — the server deliberately never loads a model on a remote
/// request (see `LocalLLMServer`), because paying a 30-second load inside
/// someone else's process is not a favour.
///
/// Transport is a Unix domain socket rather than XPC or a TCP port: it's
/// filesystem-scoped (no port to collide with, no listener reachable off-box),
/// its permissions are plain POSIX modes, and `NWListener`/`NWConnection` speak
/// it directly via `NWEndpoint.unix(path:)`.
enum LLMSocket {
    /// `~/Library/Application Support/Dictator/` — the same per-Mac directory
    /// that holds the models, the local settings file and the mic log. Not
    /// `ModelStorage.root()`, which is the `Models/` subfolder.
    static var directory: URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
        return (base ?? fm.temporaryDirectory).appendingPathComponent("Dictator", isDirectory: true)
    }

    /// Absolute filesystem path of the socket. `sockaddr_un.sun_path` is 104
    /// bytes on Darwin; this path is ~60 for a normal home directory, so there
    /// is headroom but not unlimited headroom — don't nest it deeper.
    static var path: String {
        directory.appendingPathComponent("llm.sock", isDirectory: false).path
    }

    /// Creates (or tightens) the containing directory at mode 0700 so that only
    /// the logged-in user can even see the socket, let alone connect to it. The
    /// socket file itself is chmod'ed 0600 by the server once the listener is
    /// ready — a bound socket's mode is set by the kernel from the process
    /// umask, which we can't rely on.
    @discardableResult
    static func prepareDirectory() throws -> URL {
        let dir = directory
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                                  ofItemAtPath: dir.path)
        } else {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        return dir
    }
}

/// Client → server. Exactly one per connection, one line of UTF-8 JSON
/// terminated by `\n`.
struct LLMWireRequest: Codable, Sendable {
    /// Protocol version. Bumped only for a breaking change; the server rejects
    /// anything it doesn't recognise with `badRequest` rather than guessing.
    var v: Int = 1
    var op: Op
    /// `.complete` — the system prompt.
    var system: String?
    /// `.complete` — the user message. The caller renders any multi-turn shape
    /// (prior turns, summaries, a selection + instruction) into this single
    /// string; the wire has no notion of a conversation.
    var user: String?
    /// `.complete` — reply budget in tokens.
    var maxTokens: Int?
    /// `.complete`. Forwarded to the engine (clamped to 0…2 by the server);
    /// absent means 0, the deterministic default every in-process caller uses.
    var temperature: Double?
    /// Reserved. The server treats every socket request as `.background`
    /// regardless: a remote caller must never be able to outrank the local
    /// user's dictation.
    var priority: Priority?
    /// Free-form client identity for the log, e.g. `"DictatorMeetings/2026.9.0"`.
    var client: String?

    enum Op: String, Codable, Sendable { case status, complete }
    enum Priority: String, Codable, Sendable { case background, interactive }

    init(op: Op,
         system: String? = nil,
         user: String? = nil,
         maxTokens: Int? = nil,
         temperature: Double? = nil,
         priority: Priority? = nil,
         client: String? = nil) {
        self.v = 1
        self.op = op
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.priority = priority
        self.client = client
    }
}

extension LLMWireRequest {
    /// Hand-written because Swift's synthesised `init(from:)` does NOT fall back
    /// to a property's default value for a missing key — it throws
    /// `keyNotFound`. `v` has a default, so an older or hand-rolled client that
    /// omits it must still decode.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        self.op = try c.decode(Op.self, forKey: .op)
        self.system = try c.decodeIfPresent(String.self, forKey: .system)
        self.user = try c.decodeIfPresent(String.self, forKey: .user)
        self.maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        self.priority = try c.decodeIfPresent(Priority.self, forKey: .priority)
        self.client = try c.decodeIfPresent(String.self, forKey: .client)
    }
}

/// Server → client. One or more lines; the last one is always `.done` or
/// `.error`, after which the server closes the connection.
struct LLMWireResponse: Codable, Sendable {
    var type: Kind

    /// `.chunk` (a streamed piece) or `.done` (the whole reply). v1 only ever
    /// sends `.done`.
    var text: String?
    /// `.done`, when the engine reports usage. nil when it doesn't (Apple
    /// Foundation doesn't).
    var promptTokens: Int?
    var completionTokens: Int?

    /// `.status` fields.
    var engine: String?          // "mlx" | "apple" | "none"
    var modelID: String?
    /// True only when a request could be served *right now* without loading
    /// anything. This is the field the client branches on.
    var loaded: Bool?
    /// Whether the loaded model is good enough for meeting notes
    /// (`ModelCatalog.LLMModel.meetingsCapable`). Advisory — the client decides
    /// what to do about a "yes but weak" answer.
    var meetingsCapable: Bool?
    var contextWindowTokens: Int?

    /// `.error` fields.
    var code: Code?
    var message: String?
    /// How long the client should wait before retrying, for the two transient
    /// codes (`preempted`, `busy`). nil means "don't retry".
    var retryAfterMs: Int?

    enum Kind: String, Codable, Sendable { case status, chunk, done, error }
    enum Code: String, Codable, Sendable {
        /// A local dictation took the model mid-generation. Retry shortly.
        case preempted
        /// Sharing is off, no engine is selected, or nothing is loaded. The
        /// client should fall back to its own engine — retrying won't help.
        case unavailable
        /// Another remote generation is already running. Retry shortly.
        case busy
        /// Unparseable, unknown op, or unsupported protocol version.
        case badRequest
        /// The engine itself threw.
        case engineError
    }

    init(type: Kind,
         text: String? = nil,
         promptTokens: Int? = nil,
         completionTokens: Int? = nil,
         engine: String? = nil,
         modelID: String? = nil,
         loaded: Bool? = nil,
         meetingsCapable: Bool? = nil,
         contextWindowTokens: Int? = nil,
         code: Code? = nil,
         message: String? = nil,
         retryAfterMs: Int? = nil) {
        self.type = type
        self.text = text
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.engine = engine
        self.modelID = modelID
        self.loaded = loaded
        self.meetingsCapable = meetingsCapable
        self.contextWindowTokens = contextWindowTokens
        self.code = code
        self.message = message
        self.retryAfterMs = retryAfterMs
    }

    static func error(_ code: Code, _ message: String, retryAfterMs: Int? = nil) -> LLMWireResponse {
        LLMWireResponse(type: .error, code: code, message: message, retryAfterMs: retryAfterMs)
    }
}

/// Newline framing. Both ends go through these so the "where does a message
/// end" rule lives in exactly one place.
enum LLMWire {
    /// The `\n` terminator, as a byte, for callers scanning a receive buffer.
    static let newline: UInt8 = 0x0A

    /// Largest single request we'll buffer before giving up on a client. A
    /// meeting map-reduce chunk is tens of KB of transcript; 8 MB is far above
    /// anything legitimate and well below "a malformed client can exhaust RAM".
    static let maxMessageBytes = 8 * 1024 * 1024

    /// JSON, then a newline. JSON never contains a raw newline inside a string
    /// (they're escaped as `\n`), so the terminator is unambiguous without any
    /// length prefix.
    static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order keeps the logs and the scratch check readable; the
        // cost is negligible at these sizes.
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(newline)
        return data
    }

    /// Decodes one framed line. The trailing newline is optional so callers can
    /// pass either the slice up to the terminator or the slice including it.
    static func decode<T: Decodable>(_ line: Data) throws -> T {
        var body = line
        if body.last == newline { body.removeLast() }
        return try JSONDecoder().decode(T.self, from: body)
    }
}
