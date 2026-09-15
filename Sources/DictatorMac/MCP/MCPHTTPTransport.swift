import Foundation

/// MCP over Streamable HTTP — the transport remote/hosted servers use.
///
/// One POST per message to a single endpoint. The awkward part, and the reason
/// this isn't just "post some JSON", is that the server chooses how to answer:
/// `application/json` with one object, or `text/event-stream` with an SSE
/// stream that may carry any number of server-initiated messages before the
/// response we're actually waiting for. The client MUST handle both, so this
/// reads the stream until it sees a response whose id matches the request.
///
/// Deliberately not implementing the deprecated 2024-11-05 HTTP+SSE transport
/// (GET first, `endpoint` event, POST elsewhere). It's a second protocol's
/// worth of code for servers that are being retired, and failing with a clear
/// message beats half-supporting it.
actor MCPHTTPTransport: MCPTransport {
    private let config: MCPServerConfig
    private let endpoint: URL
    private let session: URLSession

    private var nextRequestID = 1
    /// Issued by the server on the initialize response; echoed on everything
    /// afterwards. Absent for stateless servers, which is legal.
    private var sessionID: String?
    private var negotiatedVersion = MCPClient.protocolVersion
    private var lastFailure = ""

    init?(config: MCPServerConfig) {
        guard let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        self.config = config
        self.endpoint = url
        let configuration = URLSessionConfiguration.ephemeral
        // Per-request deadlines are enforced by the caller's `timeout`; these
        // are the backstops for a connection that never establishes at all.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = [:]
        self.session = URLSession(configuration: configuration)
    }

    var diagnostics: String { lastFailure }

    func setNegotiatedProtocolVersion(_ version: String) {
        negotiatedVersion = version
    }

    func connect() async throws {
        // Nothing to open: the first POST is the connection. Kept so the
        // protocol reads the same for both transports.
    }

    func disconnect() async {
        // Tell the server we're done so it can drop the session rather than
        // wait one out. 405 here is explicitly allowed and means "I don't do
        // session termination", so any failure is ignorable.
        guard let sessionID else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        _ = try? await session.data(for: request)
        self.sessionID = nil
    }

    // MARK: - Messages

    func request(_ method: String, params: MCPJSON?, timeout: Int) async throws -> MCPJSON {
        let id = nextRequestID
        nextRequestID += 1
        var message: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { message["params"] = params }

        // `let` because the timeout helper's closure is @Sendable and can't
        // capture a var.
        let payload = message
        do {
            return try await withTimeout(seconds: timeout, method: method) {
                try await self.post(payload, expectingResponseTo: id, method: method)
            }
        } catch let error as MCPError {
            // A server that has expired our session answers 404. The spec says
            // to start a new one with a fresh `initialize` and no session id —
            // so drop it and let the caller's reconnect handle the rest.
            if case .sessionExpired = error { sessionID = nil }
            throw error
        }
    }

    func notify(_ method: String, params: MCPJSON?) async throws {
        var message: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { message["params"] = params }
        _ = try await post(message, expectingResponseTo: nil, method: method)
    }

    /// POSTs one message. When `expectingResponseTo` is nil this is a
    /// notification and a 202 with no body is the success case.
    private func post(
        _ message: [String: MCPJSON], expectingResponseTo id: Int?, method: String
    ) async throws -> MCPJSON {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, always: the server picks, and refusing one of them is how you
        // get a 406 from a server that only streams.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (name, value) in MCPEnvironment.httpHeaders(for: config) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try encode(MCPJSON.object(message))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportClosed("the server sent no HTTP response")
        }

        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
            sessionID = issued
        }

        switch http.statusCode {
        case 404 where sessionID != nil:
            lastFailure = "the session expired"
            throw MCPError.sessionExpired
        case 401, 403:
            lastFailure = "HTTP \(http.statusCode) — check the server's token"
            throw MCPError.unauthorized(http.statusCode)
        case 405 where id == nil:
            // Some servers reject notifications outright. Harmless.
            return .object([:])
        case 200...299:
            break
        default:
            let body = try? await collect(bytes, limit: 400)
            lastFailure = "HTTP \(http.statusCode)"
            throw MCPError.http(status: http.statusCode, body: body ?? "")
        }

        // 202 Accepted with no body is the documented answer to a
        // notification, and there is nothing to read.
        guard let id else { return .object([:]) }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            return try await readSSE(bytes, awaitingID: id, method: method)
        }
        let body = try await collect(bytes, limit: 8 * 1024 * 1024)
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              case .object(let parsed) = MCPJSON.from(object)
        else { throw MCPError.malformed("the response to \(method) wasn't JSON") }
        return try unwrap(parsed, method: method)
    }

    /// Reads an SSE stream until the response for `id` arrives.
    ///
    /// Splits the byte stream by hand rather than using
    /// `URLSession.AsyncBytes.lines`, because that sequence **drops empty
    /// lines** — and in SSE the empty line *is* the delimiter: it's what marks
    /// the end of an event. Using `.lines`, every event ran into the next and
    /// none was ever dispatched, so a perfectly good response sat there until
    /// the stream closed and the call failed with "the stream ended before
    /// tools/call was answered". Verified against the raw bytes.
    ///
    /// Everything on the stream other than our response — server-initiated
    /// requests, progress and log notifications — is skipped rather than
    /// answered. We advertise no client capabilities, so a server has nothing
    /// it can legitimately ask us for, and over HTTP an unanswered request
    /// can't wedge a shared pipe the way it could on stdio.
    private func readSSE(
        _ bytes: URLSession.AsyncBytes, awaitingID id: Int, method: String
    ) async throws -> MCPJSON {
        var event = Data()
        var previousWasNewline = false

        for try await byte in bytes {
            if byte == 0x0D { continue }   // CR: SSE allows CRLF, we normalise
            if byte == 0x0A {
                if previousWasNewline {
                    if let result = try dispatch(event: event, awaitingID: id, method: method) {
                        return result
                    }
                    event.removeAll(keepingCapacity: true)
                    previousWasNewline = false
                    continue
                }
                previousWasNewline = true
                event.append(byte)
                continue
            }
            previousWasNewline = false
            event.append(byte)
        }

        // A stream that ends without a trailing blank line still owes us its
        // last event.
        if let result = try dispatch(event: event, awaitingID: id, method: method) {
            return result
        }
        throw MCPError.transportClosed("the stream ended before \(method) was answered")
    }

    /// Parses one SSE event block. Returns the JSON-RPC result when the block
    /// is the response we're waiting for, nil for anything else.
    private func dispatch(event: Data, awaitingID id: Int, method: String) throws -> MCPJSON? {
        guard !event.isEmpty, let text = String(data: event, encoding: .utf8) else { return nil }
        // `event:`, `id:` and `retry:` are not needed: we don't resume streams,
        // so there's no Last-Event-ID to track.
        let payload = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              case .object(let parsed) = MCPJSON.from(object)
        else { return nil }
        guard case .int(let responseID)? = parsed["id"], responseID == id,
              parsed["method"] == nil
        else { return nil }
        return try unwrap(parsed, method: method)
    }

    private func unwrap(_ message: [String: MCPJSON], method: String) throws -> MCPJSON {
        if let error = message["error"]?.objectValue {
            let code: Int
            if case .int(let value)? = error["code"] { code = value } else { code = -1 }
            throw MCPError.rpc(
                code: code, message: error["message"]?.stringValue ?? "unknown error")
        }
        return message["result"] ?? .object([:])
    }

    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func encode(_ json: MCPJSON) throws -> Data {
        guard JSONSerialization.isValidJSONObject(json.jsonObject),
              let data = try? JSONSerialization.data(withJSONObject: json.jsonObject)
        else { throw MCPError.malformed("couldn't encode the request") }
        return data
    }

    /// URLSession's own timeouts cover a stalled connection, not a server that
    /// holds an SSE stream open forever without answering.
    private func withTimeout(
        seconds: Int, method: String, _ work: @escaping @Sendable () async throws -> MCPJSON
    ) async throws -> MCPJSON {
        try await withThrowingTaskGroup(of: MCPJSON.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPError.timedOut(method: method, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw MCPError.transportClosed("")
            }
            return first
        }
    }
}
