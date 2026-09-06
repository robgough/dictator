import Foundation
@preconcurrency import Network

/// Publishes Dictator's already-loaded LLM on a Unix domain socket so Dictator
/// Meetings can borrow it instead of loading a second multi-GB copy of the same
/// checkpoint into RAM.
///
/// Three rules shape everything here:
///
/// 1. **Never load a model for a remote caller.** If nothing is resident the
///    answer is `unavailable`, immediately. Loading takes tens of seconds and
///    gigabytes; deciding to pay that is the *user's* call, made in the app they
///    are looking at. Meetings falls back to its own engine and says so.
/// 2. **Dictation always wins.** Remote work runs through
///    `LLMScheduler.run(.background)`, so the moment a dictation pass starts it
///    is cancelled at the next token and the caller gets `preempted` with a
///    retry hint. The wire's `priority` field is accepted and ignored for
///    exactly this reason — a remote process cannot promote itself.
/// 3. **Local only.** A Unix socket has no network surface at all: it lives at
///    `~/Library/Application Support/Dictator/llm.sock`, inside a 0700
///    directory, chmod'ed 0600. Another user on the same Mac cannot open it.
///
/// One request per connection, newline-framed JSON in both directions
/// (`LLMWire`). Lives in `Sources/Dictator` rather than `DictatorMac` because
/// only Dictator ever serves — Meetings is always the client.
@MainActor
final class LocalLLMServer {
    static let shared = LocalLLMServer()

    private var listener: NWListener?
    /// Live connections, kept alive for the duration of their request (an
    /// NWConnection with no strong reference gets torn down mid-flight).
    private var connections: Set<ConnectionBox> = []

    private init() {}

    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    /// Idempotent. Safe to call at launch and again on every settings save.
    func start() {
        guard listener == nil else { return }
        do {
            try LLMSocket.prepareDirectory()
            // A socket file left behind by a crash makes bind() fail with
            // EADDRINUSE even though nothing is listening. Single-instance
            // guard means no other Dictator can legitimately own it.
            try? FileManager.default.removeItem(atPath: LLMSocket.path)

            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .unix(path: LLMSocket.path)
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
            NSLog("[Dictator] LLM socket server starting at %@", LLMSocket.path)
        } catch {
            NSLog("[Dictator] LLM socket server failed to start: %@", error.localizedDescription)
            listener = nil
        }
    }

    /// Tears the listener down and removes the socket file, so a Meetings
    /// instance checking "does the file exist" gets the right answer without
    /// having to connect first.
    func stop() {
        guard listener != nil || !connections.isEmpty else { return }
        for box in connections { box.connection.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: LLMSocket.path)
        NSLog("[Dictator] LLM socket server stopped")
    }

    /// Start or stop to match the current setting. Called from `AppState.save()`
    /// so flipping the toggle in Settings → General takes effect immediately,
    /// in both directions.
    func applySettings(_ settings: DictatorSettings) {
        if settings.shareLoadedModelEnabled {
            start()
        } else {
            stop()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            // The kernel creates the socket file with the process umask, which
            // typically leaves it group/other-readable. Tighten it now that it
            // exists.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: LLMSocket.path)
            NSLog("[Dictator] LLM socket server ready")
        case .failed(let error):
            NSLog("[Dictator] LLM socket listener failed: %@ — sharing disabled until relaunch",
                  error.localizedDescription)
            stop()
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - Connections

    /// Hashable wrapper so connections can live in a Set. `NWConnection` is a
    /// class, but identity-hashing it directly means relying on its
    /// `Hashable`/`Equatable` conformance, which it doesn't advertise.
    /// `@unchecked Sendable` because the box is immutable (`let connection`)
    /// and `NWConnection` is itself thread-safe — Network's callbacks fire on
    /// the queue we hand them, and the box only ever carries identity.
    private final class ConnectionBox: Hashable, @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
        static func == (a: ConnectionBox, b: ConnectionBox) -> Bool { a === b }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    private func accept(_ connection: NWConnection) {
        let box = ConnectionBox(connection)
        connections.insert(box)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.connections.remove(box) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(box, buffer: Data(), startedAt: Date())
    }

    /// Accumulates bytes until the first newline, then dispatches that one line.
    /// Anything after the newline on the same connection is ignored: the
    /// protocol is one request per connection.
    private func receive(_ box: ConnectionBox, buffer: Data, startedAt: Date) {
        box.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            let chunk = data
            let complete = isComplete
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let chunk, !chunk.isEmpty { buffer.append(chunk) }

                if let index = buffer.firstIndex(of: LLMWire.newline) {
                    let line = Data(buffer[buffer.startIndex..<index])
                    await self.dispatch(line: line, on: box, startedAt: startedAt)
                    return
                }
                if buffer.count > LLMWire.maxMessageBytes {
                    self.finish(box, with: .error(.badRequest, "Request exceeded \(LLMWire.maxMessageBytes) bytes."))
                    return
                }
                if failed || complete {
                    // Client hung up (or errored) without ever sending a
                    // terminator. Nothing to answer.
                    self.close(box)
                    return
                }
                self.receive(box, buffer: buffer, startedAt: startedAt)
            }
        }
    }

    private func dispatch(line: Data, on box: ConnectionBox, startedAt: Date) async {
        let request: LLMWireRequest
        do {
            request = try LLMWire.decode(line)
        } catch {
            NSLog("[Dictator] LLM socket: malformed request (%d bytes): %@",
                  line.count, error.localizedDescription)
            finish(box, with: .error(.badRequest, "Could not decode request: \(error.localizedDescription)"))
            return
        }

        let client = request.client ?? "unknown"
        guard request.v == 1 else {
            log(client: client, op: request.op.rawValue, promptChars: 0,
                outcome: "badRequest(v=\(request.v))", startedAt: startedAt)
            finish(box, with: .error(.badRequest, "Unsupported protocol version \(request.v)."))
            return
        }

        switch request.op {
        case .status:
            let response = statusResponse()
            log(client: client, op: "status", promptChars: 0,
                outcome: "engine=\(response.engine ?? "?") loaded=\(response.loaded ?? false)",
                startedAt: startedAt)
            finish(box, with: response)

        case .complete:
            await runComplete(request, client: client, on: box, startedAt: startedAt)
        }
    }

    // MARK: - Ops

    private func statusResponse() -> LLMWireResponse {
        let settings = AppState.shared.settings
        let kind = settings.llmEngine

        // Sharing off is reported as "not loaded" rather than as an error: the
        // client's question is "can I borrow a model", and the answer is no.
        guard settings.shareLoadedModelEnabled else {
            return LLMWireResponse(type: .status, engine: kind.rawValue, loaded: false,
                                   message: "Model sharing is switched off in Dictator's settings.")
        }

        switch kind {
        case .none:
            return LLMWireResponse(type: .status, engine: kind.rawValue, loaded: false,
                                   message: "Dictator has no LLM selected.")
        case .apple:
            let usable = AppleFoundationAvailability.isUsable
            return LLMWireResponse(
                type: .status,
                engine: kind.rawValue,
                modelID: "apple-on-device",
                loaded: usable,
                meetingsCapable: AppleFoundationAvailability.isMeetingsCapable,
                contextWindowTokens: AppleFoundationAvailability.contextSize
            )
        case .mlx:
            let id = settings.llmModelID
            let loaded = MLXLLMServiceHolder.shared.isLoaded(modelID: id)
            let catalogued = ModelCatalog.llm(id: id)
            return LLMWireResponse(
                type: .status,
                engine: kind.rawValue,
                modelID: id,
                loaded: loaded,
                meetingsCapable: catalogued?.meetingsCapable ?? false,
                contextWindowTokens: catalogued?.contextWindowTokens ?? ModelCatalog.fallbackContextWindowTokens
            )
        }
    }

    /// Either an engine ready to serve a remote `complete` right now, or the
    /// refusal to send back instead.
    private enum EngineResolution {
        case ready(any LLMEngine)
        case refused(LLMWireResponse)
    }

    /// Resolves the engine to serve a remote `complete` with, or the refusal to
    /// send instead. Never loads anything.
    private func readyEngine() -> EngineResolution {
        let settings = AppState.shared.settings
        guard settings.shareLoadedModelEnabled else {
            return .refused(.error(.unavailable, "Model sharing is switched off in Dictator's settings."))
        }
        switch settings.llmEngine {
        case .none:
            return .refused(.error(.unavailable, "Dictator has no LLM selected."))
        case .apple:
            guard AppleFoundationAvailability.isUsable else {
                return .refused(.error(.unavailable,
                                       AppleFoundationAvailability.unavailableMessage
                                       ?? "Apple's on-device model is unavailable."))
            }
            return .ready(AppleFoundationLLMServiceHolder.shared)
        case .mlx:
            let id = settings.llmModelID
            let mlx = MLXLLMServiceHolder.shared
            guard mlx.isLoaded(modelID: id) else {
                return .refused(.error(.unavailable, "Dictator has no model loaded right now."))
            }
            mlx.modelID = id
            return .ready(mlx)
        }
    }

    private func runComplete(_ request: LLMWireRequest,
                             client: String,
                             on box: ConnectionBox,
                             startedAt: Date) async {
        let system = request.system ?? ""
        let user = request.user ?? ""
        guard !user.isEmpty else {
            log(client: client, op: "complete", promptChars: 0, outcome: "badRequest(no user)", startedAt: startedAt)
            finish(box, with: .error(.badRequest, "`user` is required for a complete request."))
            return
        }
        // Same shape as the in-process callers: the caller states its budget,
        // we clamp it to something a runaway client can't turn into an
        // open-ended generation.
        let maxTokens = min(max(request.maxTokens ?? 1024, 1), 16_384)
        // Honoured now that `LLMEngine.complete` takes one. Clamped to the
        // usual 0…2 band so a malformed client can't ask for nonsense; absent
        // means 0, the deterministic default every in-process caller uses.
        let temperature = min(max(request.temperature ?? 0, 0), 2)

        let engine: any LLMEngine
        switch readyEngine() {
        case .ready(let resolved):
            engine = resolved
        case .refused(let refusal):
            log(client: client, op: "complete", promptChars: user.count,
                outcome: "unavailable", startedAt: startedAt)
            finish(box, with: refusal)
            return
        }

        do {
            let result = try await LLMScheduler.shared.run(.background) { () -> LLMCompletionResult in
                if let reporting = engine as? LLMUsageReporting {
                    return try await reporting.completeReportingUsage(system: system, user: user,
                                                                      maxTokens: maxTokens,
                                                                      temperature: temperature)
                }
                let text = try await engine.complete(system: system, user: user,
                                                     maxTokens: maxTokens, temperature: temperature)
                return LLMCompletionResult(text: text, promptTokens: nil, completionTokens: nil)
            }
            log(client: client, op: "complete", promptChars: user.count,
                outcome: "done(\(result.text.count) chars)", startedAt: startedAt)
            finish(box, with: LLMWireResponse(type: .done,
                                              text: result.text,
                                              promptTokens: result.promptTokens,
                                              completionTokens: result.completionTokens))
        } catch LLMSchedulerError.preempted {
            log(client: client, op: "complete", promptChars: user.count, outcome: "preempted", startedAt: startedAt)
            finish(box, with: .error(.preempted, "Dictation took the model.", retryAfterMs: 1500))
        } catch LLMSchedulerError.busy {
            log(client: client, op: "complete", promptChars: user.count, outcome: "busy", startedAt: startedAt)
            finish(box, with: .error(.busy, "Another background generation is already running.", retryAfterMs: 3000))
        } catch {
            log(client: client, op: "complete", promptChars: user.count,
                outcome: "engineError(\(error.localizedDescription))", startedAt: startedAt)
            finish(box, with: .error(.engineError, error.localizedDescription))
        }
    }

    // MARK: - Replying

    /// Sends one response line and closes. v1 is single-reply, so "send" and
    /// "finish" are the same operation.
    private func finish(_ box: ConnectionBox, with response: LLMWireResponse) {
        let data: Data
        do {
            data = try LLMWire.encodeLine(response)
        } catch {
            NSLog("[Dictator] LLM socket: failed to encode response: %@", error.localizedDescription)
            close(box)
            return
        }
        box.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(box) }
        })
    }

    private func close(_ box: ConnectionBox) {
        box.connection.cancel()
        connections.remove(box)
    }

    private func log(client: String, op: String, promptChars: Int, outcome: String, startedAt: Date) {
        NSLog("[Dictator] LLM socket %@ op=%@ prompt=%dch -> %@ in %.2fs",
              client, op, promptChars, outcome, Date().timeIntervalSince(startedAt))
    }
}
