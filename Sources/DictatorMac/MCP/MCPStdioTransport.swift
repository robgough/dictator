import Darwin
import Foundation

/// MCP over a subprocess's stdin/stdout, newline-delimited JSON-RPC.
///
/// The transport clients should prefer where it applies: no network, no
/// credentials in flight, and the server dies with the app.
actor MCPStdioTransport: MCPTransport {
    private let config: MCPServerConfig

    private var process: Process?
    private var stdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<MCPJSON, Error>] = [:]

    /// Last few stderr lines, kept so a failed launch can say *why*. MCP
    /// servers log diagnostics there and it is usually the only clue.
    private var stderrTail: [String] = []
    private static let stderrTailLimit = 20

    /// Set when the server said its tool list changed.
    private(set) var toolsChanged = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    /// The running server's pid, for diagnostics and for the orphan check in
    /// `scratch/mcp-client-check`.
    var processIdentifier: pid_t? { process?.processIdentifier }

    var diagnostics: String { stderrTail.suffix(4).joined(separator: " / ") }

    /// stdio carries no protocol-version header — the handshake is the whole
    /// negotiation.
    func setNegotiatedProtocolVersion(_ version: String) {}

    // MARK: - Lifecycle

    func connect() async throws {

        guard process == nil else { return }
        guard let executable = MCPEnvironment.resolve(command: config.command) else {
            throw MCPError.commandNotFound(config.command)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = config.arguments
        process.environment = MCPEnvironment.environment(for: config)
        if let directory = config.workingDirectory, !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw MCPError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        // Recorded outside the actor so quit can signal it without awaiting.
        MCPProcessReaper.register(process.processIdentifier)

        // Lines are delivered through an AsyncStream fed by the pipe's
        // readability handler, and drained by exactly one consumer task.
        //
        // Not `FileHandle.bytes.lines`: it delivered lines unreliably against a
        // local server that answers in well under a millisecond, and the
        // failure looked like a hung server rather than a dropped read. The
        // handler fires serially on its own queue, so `yield` order is the wire
        // order, and a single consumer awaiting `receive` in sequence keeps it
        // that way — which matters, because a JSON-RPC stream reordered is a
        // JSON-RPC stream corrupted.
        let outHandle = outPipe.fileHandleForReading
        let (lines, lineContinuation) = AsyncStream<String>.makeStream()
        Self.pumpLines(from: outHandle, into: lineContinuation)
        readerTask = Task { [weak self] in
            for await line in lines {
                guard let self else { return }
                await self.receive(line: line)
            }
            await self?.transportEnded()
        }

        // Servers log diagnostics to stderr and nowhere else. Keeping the tail
        // is the difference between "the server stopped unexpectedly" and
        // "Error: GITHUB_TOKEN is not set".
        let errHandle = errPipe.fileHandleForReading
        let (errLines, errContinuation) = AsyncStream<String>.makeStream()
        Self.pumpLines(from: errHandle, into: errContinuation)
        stderrTask = Task { [weak self] in
            for await line in errLines {
                guard let self else { return }
                await self.appendStderr(line)
            }
        }
    }

    func disconnect() async {
        readerTask?.cancel()
        stderrTask?.cancel()
        readerTask = nil
        stderrTask = nil

        try? stdin?.close()
        stdin = nil

        if let process, process.isRunning {
            // Up to 2s for a voluntary exit after stdin closes.
            for _ in 0..<20 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 {
                    if !process.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            MCPProcessReaper.unregister(process.processIdentifier)
        }
        process = nil

        failAllPending(with: MCPError.transportClosed(""))
    }

    /// Splits a pipe into newline-delimited strings on the handle's own queue.
    ///
    /// `nonisolated static` on purpose: it touches no actor state, so it can be
    /// wired up during `connect()` without hopping, and the handler closure
    /// never captures the actor.
    private nonisolated static func pumpLines(
        from handle: FileHandle, into continuation: AsyncStream<String>.Continuation
    ) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: the server closed its end (or exited).
                handle.readabilityHandler = nil
                for line in buffer.drainRemainder() { continuation.yield(line) }
                continuation.finish()
                return
            }
            for line in buffer.append(chunk) { continuation.yield(line) }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }

    // MARK: - JSON-RPC plumbing

    func request(_ method: String, params: MCPJSON?, timeout: Int) async throws -> MCPJSON {
        guard process != nil else { throw MCPError.transportClosed(diagnostics) }
        let id = nextRequestID
        nextRequestID += 1

        var message: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { message["params"] = params }

        // The timeout task and the response race to resume the continuation;
        // `resolve(id:)` removes it from `pending` first, so only one wins.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self else { return }
            await self.fail(id: id, with: MCPError.timedOut(method: method, seconds: timeout))
        }
        defer { timeoutTask.cancel() }

        // `isolation: self` is load-bearing, not decoration. Without it the
        // continuation body is a nonisolated @Sendable closure that races the
        // reader task: the server can answer and `receive` can look for the
        // continuation *before* this closure has stored it, so the reply is
        // dropped on the floor and the call sits there until it times out.
        // That reproduced intermittently against a local server answering in
        // under a millisecond — which is exactly how fast a real stdio server
        // on the same machine replies.
        // Cancellation has to reach the continuation too. Without the handler,
        // Stop during a slow tool call did nothing visible: the turn task
        // unwound, but this call sat waiting for the server (or its 60s
        // timeout) with nothing able to interrupt it — and the chat stayed
        // busy the whole time.
        return try await withTaskCancellationHandler {
            // `isolation: self` is load-bearing, not decoration. Without it the
            // continuation body is a nonisolated @Sendable closure that races
            // the reader task: the server can answer and `receive` can look for
            // the continuation *before* this closure has stored it, so the
            // reply is dropped on the floor and the call sits there until it
            // times out. That reproduced intermittently against a local server
            // answering in under a millisecond — which is exactly how fast a
            // real stdio server on the same machine replies.
            try await withCheckedThrowingContinuation(isolation: self) { continuation in
                pending[id] = continuation
                do {
                    try send(object: message)
                } catch {
                    if let waiting = pending.removeValue(forKey: id) {
                        waiting.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.fail(id: id, with: CancellationError())
            }
        }
    }

    private func send(object: [String: MCPJSON]) throws {
        guard let stdin else { throw MCPError.transportClosed(diagnostics) }
        let json = MCPJSON.object(object)
        guard JSONSerialization.isValidJSONObject(json.jsonObject),
              var data = try? JSONSerialization.data(withJSONObject: json.jsonObject)
        else { throw MCPError.malformed("couldn't encode \(object["method"]?.stringValue ?? "message")") }
        data.append(0x0A)
        do {
            try stdin.write(contentsOf: data)
        } catch {
            throw MCPError.transportClosed(diagnostics)
        }
    }

    private func receive(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        // Servers occasionally print a banner to stdout before speaking JSON.
        // Ignore anything unparseable rather than tearing the session down.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              case .object(let message) = MCPJSON.from(object)
        else { return }

        if let idValue = message["id"], case .int(let id) = idValue, message["method"] == nil {
            // A response to one of ours.
            if let error = message["error"]?.objectValue {
                let code = error["code"].flatMap { if case .int(let c) = $0 { return c } else { return nil } } ?? -1
                fail(id: id, with: MCPError.rpc(
                    code: code, message: error["message"]?.stringValue ?? "unknown error"))
            } else {
                resolve(id: id, with: message["result"] ?? .object([:]))
            }
            return
        }

        if let method = message["method"]?.stringValue {
            if let idValue = message["id"], case .int(let id) = idValue {
                // A server→client request. We advertised no client capabilities,
                // so the honest answer is "method not found" — and it has to be
                // an answer, because a server awaiting one will otherwise sit
                // there holding up the tool call we're waiting on.
                try? send(object: [
                    "jsonrpc": .string("2.0"),
                    "id": .int(id),
                    "error": .object([
                        "code": .int(-32601),
                        "message": .string("Dictator implements no client capabilities"),
                    ]),
                ])
                return
            }
            if method == "notifications/tools/list_changed" {
                // The transport doesn't own the tool list; the client does.
                // Recorded rather than acted on: MCPRegistry re-lists on
                // reconnect and on Test, and a push-driven refresh mid-turn
                // would change the tool list under a generation that has
                // already been prompted with it.
                toolsChanged = true
            }
        }
    }

    private func resolve(id: Int, with value: MCPJSON) {
        pending.removeValue(forKey: id)?.resume(returning: value)
    }

    private func fail(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    func notify(_ method: String, params: MCPJSON?) async throws {
        var message: [String: MCPJSON] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { message["params"] = params }
        try send(object: message)
    }

    private func transportEnded() {
        guard process != nil else { return }
        failAllPending(with: MCPError.transportClosed(diagnostics))
    }

    private func appendStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
    }

}

/// Accumulates pipe chunks and hands back whole lines.
///
/// A pipe read has nothing to do with message boundaries: one `availableData`
/// can carry half a JSON-RPC message, or three of them, and a large tool result
/// reliably arrives split. Reassembling here is what makes the line protocol
/// actually a line protocol.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// Whatever is left when the pipe closes without a trailing newline.
    func drainRemainder() -> [String] {
        defer { data.removeAll() }
        guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return [] }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
