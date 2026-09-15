import Foundation

/// One tool a server exposes.
struct MCPToolDescriptor: Codable, Hashable, Sendable {
    let name: String
    let title: String?
    let description: String
    let inputSchema: MCPJSON

    var displayName: String { title ?? name }
}

/// What a `tools/call` came back with.
struct MCPToolResult: Sendable {
    /// Every text block the server returned, joined. Non-text blocks are
    /// summarised rather than dropped silently, so a model that gets an image
    /// back at least knows one arrived.
    let text: String
    /// The server reporting a *tool execution* error (`isError: true`), which
    /// the spec says to hand to the model so it can self-correct — as opposed
    /// to a protocol error, which throws.
    let isError: Bool
}

enum MCPError: LocalizedError, Sendable {
    case commandNotFound(String)
    case launchFailed(String)
    case transportClosed(String)
    case timedOut(method: String, seconds: Int)
    case rpc(code: Int, message: String)
    case malformed(String)
    case unsupportedProtocol(String)
    case http(status: Int, body: String)
    case unauthorized(Int)
    case sessionExpired
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "Couldn't find “\(command)”. Use the full path to the program, or install it somewhere on your PATH."
        case .launchFailed(let detail):
            return "The server didn't start: \(detail)"
        case .transportClosed(let detail):
            return detail.isEmpty
                ? "The server stopped unexpectedly."
                : "The server stopped unexpectedly: \(detail)"
        case .timedOut(let method, let seconds):
            return "The server didn't answer \(method) within \(seconds)s."
        case .rpc(let code, let message):
            return "The server returned an error (\(code)): \(message)"
        case .malformed(let detail):
            return "The server sent something we couldn't read: \(detail)"
        case .unsupportedProtocol(let version):
            return "The server speaks MCP \(version), which this version of Dictator doesn't support."
        case .http(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            return detail.isEmpty
                ? "The server returned HTTP \(status)."
                : "The server returned HTTP \(status): \(detail)"
        case .unauthorized(let status):
            return "The server refused the request (HTTP \(status)). Check the token in this server's settings."
        case .sessionExpired:
            return "The server ended the session. Reconnecting will start a new one."
        case .badURL(let url):
            return url.isEmpty
                ? "This server has no address. Add its URL."
                : "“\(url)” isn't a valid http:// or https:// address."
        }
    }
}

/// A Model Context Protocol client.
///
/// Owns the protocol — handshake, version negotiation, tool listing, tool
/// calls — and nothing about how bytes move. That's `MCPTransport`, of which
/// there are two: a subprocess over stdio, and Streamable HTTP for hosted
/// servers.
///
/// Hand-rolled rather than taking `modelcontextprotocol/swift-sdk`, which pulls
/// swift-nio, swift-log, swift-system, an EventSource package and
/// `swift-docc-plugin` pinned to `branch: "main"`. An unpinned branch in a
/// shipping app's dependency graph is exactly the hazard that made the
/// swift-transformers diamond so expensive (see CLAUDE.md, "Dependencies").
/// Same reasoning as `HubBridge`.
///
/// Scope is deliberately narrow: `initialize`, `tools/list`, `tools/call`. No
/// resources, prompts, sampling or elicitation.
actor MCPClient {
    /// The version we advertise. Not the newest published spec (`2026-07-28`,
    /// which makes `_meta` mandatory on every request and adds `resultType`) —
    /// this is the one servers in the wild actually implement. Negotiation
    /// means a newer server answers with its own version and keeps talking, and
    /// the parsing below ignores unknown fields.
    static let protocolVersion = "2025-06-18"

    /// Versions we know we can talk to if the server insists on one of its own.
    private static let acceptedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2026-07-28",
    ]

    /// What we report as `clientInfo.version`. Some servers gate behaviour on
    /// the client, so send the real build rather than a placeholder.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    let config: MCPServerConfig
    private let transport: any MCPTransport

    private(set) var tools: [MCPToolDescriptor] = []
    private(set) var serverName: String?
    private(set) var instructions: String?
    private(set) var isRunning = false

    init(config: MCPServerConfig) throws {
        self.config = config
        switch config.kind {
        case .stdio:
            self.transport = MCPStdioTransport(config: config)
        case .http:
            guard let http = MCPHTTPTransport(config: config) else {
                throw MCPError.badURL(config.url)
            }
            self.transport = http
        }
    }

    /// The pid of the subprocess, when this is a stdio server. nil for HTTP.
    var processIdentifier: pid_t? {
        get async {
            guard let stdio = transport as? MCPStdioTransport else { return nil }
            return await stdio.processIdentifier
        }
    }

    // MARK: - Lifecycle

    /// Connects, negotiates, and loads the tool list.
    func start() async throws {
        guard !isRunning else { return }
        try await transport.connect()
        isRunning = true
        do {
            try await handshake()
            try await refreshTools()
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        isRunning = false
        await transport.disconnect()
    }

    // MARK: - Protocol

    private func handshake() async throws {
        let result = try await transport.request(
            "initialize",
            params: .object([
                "protocolVersion": .string(Self.protocolVersion),
                // We implement none of the client-side capabilities, and saying
                // so matters: a server that sees `sampling` advertised may try
                // to call back into us mid-tool-call and hang.
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Dictator"),
                    "version": .string(Self.appVersion),
                ]),
            ]),
            timeout: 30
        )

        let version = result["protocolVersion"]?.stringValue ?? Self.protocolVersion
        guard Self.acceptedProtocolVersions.contains(version) else {
            throw MCPError.unsupportedProtocol(version)
        }
        await transport.setNegotiatedProtocolVersion(version)
        serverName = result["serverInfo"]?["name"]?.stringValue
        instructions = result["instructions"]?.stringValue

        // A notification, so there's nothing to await — but it must be sent
        // before any other request or a strict server refuses everything.
        try await transport.notify("notifications/initialized", params: nil)
    }

    /// (Re)loads the tool list, following pagination.
    func refreshTools() async throws {
        var collected: [MCPToolDescriptor] = []
        var cursor: String?
        // Bounded: a server that returns the same cursor forever shouldn't spin
        // us until the app is killed.
        for _ in 0..<20 {
            var params: [String: MCPJSON] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await transport.request(
                "tools/list", params: .object(params), timeout: 30)
            for entry in result["tools"]?.arrayValue ?? [] {
                guard let name = entry["name"]?.stringValue else { continue }
                collected.append(
                    MCPToolDescriptor(
                        name: name,
                        title: entry["title"]?.stringValue,
                        description: entry["description"]?.stringValue ?? "",
                        inputSchema: entry["inputSchema"] ?? .object([:])
                    ))
            }
            guard let next = result["nextCursor"]?.stringValue, next != cursor else { break }
            cursor = next
        }
        tools = collected
    }

    /// Invokes a tool. Throws on protocol errors; returns `isError: true` for
    /// tool-execution errors, which the spec says to feed back to the model.
    func callTool(name: String, arguments: MCPJSON, timeout: Int = 60) async throws -> MCPToolResult {
        let result = try await transport.request(
            "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]),
            timeout: timeout
        )
        var pieces: [String] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                pieces.append(block["text"]?.stringValue ?? "")
            case "resource":
                // Embedded resource: the text is what a model can use.
                if let text = block["resource"]?["text"]?.stringValue {
                    pieces.append(text)
                } else if let uri = block["resource"]?["uri"]?.stringValue {
                    pieces.append("[resource: \(uri)]")
                }
            case "resource_link":
                pieces.append("[link: \(block["uri"]?.stringValue ?? "")]")
            case "image", "audio":
                // Say it arrived rather than dropping it. The local models
                // can't be handed a tool-returned image today.
                pieces.append("[\(block["type"]?.stringValue ?? "binary") content returned]")
            default:
                break
            }
        }
        // Some servers answer only with `structuredContent`, even though the
        // spec asks them to mirror it into a text block.
        if pieces.isEmpty, let structured = result["structuredContent"] {
            pieces.append(structured.compactString)
        }
        return MCPToolResult(
            text: pieces.joined(separator: "\n"),
            isError: result["isError"]?.boolValue ?? false
        )
    }

    /// Whatever the transport can say about the last failure.
    var diagnostics: String {
        get async { await transport.diagnostics }
    }
}
