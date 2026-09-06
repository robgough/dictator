import Foundation
import AppKit
import Network

/// Borrows the LLM Dictator already has loaded, over the Unix domain socket at
/// `LLMSocket.path`.
///
/// This is the default for both slots, and it's the one provider that costs
/// nothing: most people run Dictator all day with a model resident, so writing
/// notes with it means no second multi-gigabyte copy in RAM and no cold load.
/// The trade is that it's only there when Dictator is — hence `isAvailable`,
/// which `ProviderRegistry` checks before handing this out, falling back to the
/// in-process providers when Dictator is closed or sharing is off.
///
/// Dictation always wins: Dictator's scheduler preempts an in-flight meeting
/// generation at the next token and answers `.preempted`, which we back off and
/// retry rather than surfacing as a failure. A generation that gets preempted
/// six times in a row is a user who's dictating continuously, and at that point
/// the honest thing is to fail and let the caller fall back.
@MainActor
final class DictatorSocketProvider: MeetingLLM {
    /// Dictator's bundle id. A socket file with no process behind it is a
    /// stale file from a crash, so both checks have to pass.
    nonisolated static let dictatorBundleID = "net.robgough.Dictator"

    /// A meeting map-reduce chunk on a 7B model genuinely takes minutes, and
    /// the socket has no keep-alive — so the ceiling is generous. The user can
    /// always stop the meeting, which trips `cancellation`.
    private static let completeTimeout: TimeInterval = 600
    /// `status` is a dictionary lookup on the other side; if it doesn't answer
    /// promptly something is wrong and we want the fallback, not a stall.
    private static let statusTimeout: TimeInterval = 5

    private static let maxRetries = 6

    let id: String
    let displayName: String
    var isLocal: Bool { true }

    /// Last `status` reply, cached by `prepare()`. Nil until the first
    /// successful status round-trip.
    private var status: LLMWireResponse?

    init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.name.isEmpty ? ProviderConfig.Kind.dictator.displayName : config.name
    }

    /// Whether it's worth trying at all: the socket file is present AND
    /// Dictator is running. Checked by `ProviderRegistry` on every slot
    /// resolution, so it must stay cheap — two syscalls.
    static var isAvailable: Bool {
        guard FileManager.default.fileExists(atPath: LLMSocket.path) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: dictatorBundleID).isEmpty
    }

    /// The remote model's context window, so `MeetingSummaryService` chunks
    /// against the model that will actually answer. Falls back to the catalog
    /// floor before the first `status`.
    var contextWindowTokens: Int {
        status?.contextWindowTokens ?? ModelCatalog.fallbackContextWindowTokens
    }

    /// The wire protocol carries no output cap — Dictator's `complete` honours
    /// the `maxTokens` we send — so this is our own ceiling, matching the
    /// largest reply a meeting pass ever asks for.
    var maxOutputTokens: Int { 8_192 }

    /// The remote model id, once known. Shown on the Providers row so "Dictator's
    /// model" is not a mystery box.
    var remoteModelDescription: String? {
        guard let status else { return nil }
        if let modelID = status.modelID, !modelID.isEmpty { return modelID }
        return status.engine
    }

    /// True when the remote model is one meetings notes are worth keeping from.
    /// nil when we haven't asked yet.
    var remoteIsMeetingsCapable: Bool? { status?.meetingsCapable }

    // MARK: - MeetingLLM

    func prepare() async throws {
        guard Self.isAvailable else {
            throw MeetingLLMError.unavailable("Dictator isn't running, so there's no loaded model to borrow.")
        }
        let reply = try await requestStatus()
        guard reply.loaded == true else {
            throw MeetingLLMError.unavailable(
                "Dictator is running but has no model loaded to share. Open a dictation to load one, or switch this slot to a local model."
            )
        }
        status = reply
    }

    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String {
        try MeetingLLMCancellation.check(cancellation)
        guard Self.isAvailable else {
            throw MeetingLLMError.unavailable("Dictator isn't running, so there's no loaded model to borrow.")
        }

        let request = LLMWireRequest(
            op: .complete,
            system: system,
            user: user,
            maxTokens: max(1, maxTokens),
            temperature: temperature,
            priority: .background,
            client: Self.clientIdentifier
        )

        var attempt = 0
        while true {
            try MeetingLLMCancellation.check(cancellation)
            let responses = try await UnixSocketRequest.send(
                request,
                to: LLMSocket.path,
                timeout: Self.completeTimeout,
                cancellation: cancellation
            )

            if let error = responses.last(where: { $0.type == .error }) {
                let code = error.code
                let retryable = (code == .preempted || code == .busy)
                if retryable, attempt < Self.maxRetries {
                    attempt += 1
                    let waitMs = error.retryAfterMs ?? (code == .busy ? 3_000 : 1_500)
                    NSLog("[DictatorMeetings] Dictator socket \(code?.rawValue ?? "?") — retry \(attempt)/\(Self.maxRetries) in \(waitMs) ms")
                    try await Self.backoff(milliseconds: waitMs, cancellation: cancellation)
                    continue
                }
                throw Self.mapped(error)
            }

            // v1 sends one `.done` with the whole reply; `.chunk` is in the
            // protocol so streaming can land without a version bump, so
            // concatenate defensively rather than assuming.
            let chunks = responses.filter { $0.type == .chunk }.compactMap(\.text).joined()
            let done = responses.last { $0.type == .done }
            let doneText = done?.text ?? ""
            let text = doneText.isEmpty ? chunks : doneText
            guard !text.isEmpty else { throw MeetingLLMError.emptyResponse(displayName) }
            return text
        }
    }

    func healthCheck() async throws -> String {
        let reply = try await requestStatus()
        status = reply
        guard reply.loaded == true else {
            throw MeetingLLMError.unavailable("Dictator is running but has no model loaded to share.")
        }
        if let modelID = reply.modelID, !modelID.isEmpty { return modelID }
        return reply.engine ?? "Dictator"
    }

    // MARK: - Internals

    /// `client` string in every request, so Dictator's log says who asked.
    private static var clientIdentifier: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "DictatorMeetings/\(version)"
    }

    private func requestStatus() async throws -> LLMWireResponse {
        let request = LLMWireRequest(op: .status, client: Self.clientIdentifier)
        let responses = try await UnixSocketRequest.send(
            request,
            to: LLMSocket.path,
            timeout: Self.statusTimeout,
            cancellation: { false }
        )
        if let error = responses.last(where: { $0.type == .error }) { throw Self.mapped(error) }
        guard let reply = responses.last(where: { $0.type == .status }) else {
            throw MeetingLLMError.transport("Dictator didn't answer the status request.")
        }
        return reply
    }

    /// Sleeps between retries while still watching the cancellation closure,
    /// so stopping a meeting doesn't wait out a three-second backoff.
    private static func backoff(milliseconds: Int, cancellation: @Sendable @escaping () -> Bool) async throws {
        let step = 100
        var elapsed = 0
        while elapsed < max(0, milliseconds) {
            try MeetingLLMCancellation.check(cancellation)
            try await Task.sleep(for: .milliseconds(step))
            elapsed += step
        }
        try MeetingLLMCancellation.check(cancellation)
    }

    private static func mapped(_ error: LLMWireResponse) -> MeetingLLMError {
        let message = error.message ?? ""
        switch error.code {
        case .unavailable:
            return .unavailable(message.isEmpty
                ? "Dictator isn't sharing its model right now. Turn on Settings → General → Performance → \"Share the loaded model with Dictator Meetings\" in Dictator, or point this slot at a local model."
                : message)
        case .preempted:
            return .unavailable(message.isEmpty ? "Dictator kept taking its model back for dictation." : message)
        case .busy:
            return .unavailable(message.isEmpty ? "Dictator's model is busy with another request." : message)
        case .badRequest:
            return .badConfiguration(message.isEmpty ? "Dictator rejected the request." : message)
        case .engineError, .none:
            return .transport(message.isEmpty ? "Dictator's model failed to answer." : message)
        }
    }
}

/// One newline-delimited-JSON round trip over a Unix domain socket.
///
/// A connection per request, matching the server: no multiplexing, no
/// keep-alive, nothing to reconnect after Dictator quits. `@unchecked
/// Sendable` because every mutable field is touched only on `queue`; the
/// continuation is resumed exactly once, guarded by `finished`.
private final class UnixSocketRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.robgough.DictatorMeetings.llm-socket")
    private var connection: NWConnection?
    private var buffer = Data()
    private var responses: [LLMWireResponse] = []
    private var continuation: CheckedContinuation<[LLMWireResponse], Error>?
    private var finished = false
    /// Set when the call is torn down before `start` has stored its
    /// continuation — `withTaskCancellationHandler` can fire `onCancel`
    /// before the operation body has run. `start` checks it and resumes
    /// immediately rather than waiting on a connection nobody will answer.
    private var earlyFailure: Error?

    /// Sends one request and collects response lines until a `.done` or
    /// `.error` arrives (or the peer closes).
    ///
    /// Honours BOTH cancellation channels: `cancellation` is polled on the
    /// socket queue every 200 ms, and Swift `Task` cancellation tears the
    /// connection down through `withTaskCancellationHandler`. Either way the
    /// connection is cancelled and the call throws `.cancelled` — we never
    /// leave a socket open behind an abandoned meeting.
    static func send(_ request: LLMWireRequest,
                     to path: String,
                     timeout: TimeInterval,
                     cancellation: @Sendable @escaping () -> Bool) async throws -> [LLMWireResponse] {
        let call = UnixSocketRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.start(request: request,
                           path: path,
                           timeout: timeout,
                           cancellation: cancellation,
                           continuation: continuation)
            }
        } onCancel: {
            call.abort(with: MeetingLLMError.cancelled)
        }
    }

    private func start(request: LLMWireRequest,
                       path: String,
                       timeout: TimeInterval,
                       cancellation: @Sendable @escaping () -> Bool,
                       continuation: CheckedContinuation<[LLMWireResponse], Error>) {
        queue.async { [self] in
            if self.finished {
                continuation.resume(throwing: self.earlyFailure ?? MeetingLLMError.cancelled)
                return
            }
            self.continuation = continuation

            let line: Data
            do {
                line = try LLMWire.encodeLine(request)
            } catch {
                self.finish(.failure(MeetingLLMError.transport("Couldn't encode the request: \(error.localizedDescription)")))
                return
            }

            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(line: line, over: connection)
                case .failed(let error):
                    self.finish(.failure(MeetingLLMError.transport("Couldn't reach Dictator: \(error.localizedDescription)")))
                case .cancelled:
                    // Either we tore it down (a finish already ran) or the
                    // peer went away mid-flight.
                    self.finish(.failure(MeetingLLMError.transport("The connection to Dictator closed unexpectedly.")))
                default:
                    break
                }
            }
            connection.start(queue: self.queue)

            // Hard ceiling, so a wedged peer can't hold a meeting's post-pass
            // open forever.
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(MeetingLLMError.transport("Dictator didn't reply within \(Int(timeout)) s.")))
            }
            self.pollCancellation(cancellation)
        }
    }

    /// Watches the caller's cancellation closure on the socket queue. Cheap
    /// (a closure call every 200 ms) and it's the only way to interrupt a
    /// generation that's already been handed to the other process.
    private func pollCancellation(_ cancellation: @Sendable @escaping () -> Bool) {
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, !self.finished else { return }
            if cancellation() {
                self.finish(.failure(MeetingLLMError.cancelled))
                return
            }
            self.pollCancellation(cancellation)
        }
    }

    private func send(line: Data, over connection: NWConnection) {
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(MeetingLLMError.transport("Couldn't send to Dictator: \(error.localizedDescription)")))
                return
            }
            self.receive(over: connection)
        })
    }

    private func receive(over connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(MeetingLLMError.transport("Couldn't read from Dictator: \(error.localizedDescription)")))
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.drainLines() { return }
            }
            if isComplete {
                // Peer closed without a terminal frame. Anything we already
                // parsed still counts; an empty haul is a transport failure.
                _ = self.drainLines()
                if self.responses.isEmpty {
                    self.finish(.failure(MeetingLLMError.transport("Dictator closed the connection without replying.")))
                } else {
                    self.finish(.success(self.responses))
                }
                return
            }
            self.receive(over: connection)
        }
    }

    /// Splits whatever's buffered on `\n`, decodes each complete line, and
    /// returns true when a terminal frame finished the call. Malformed lines
    /// are skipped rather than fatal — a future server version may add frame
    /// kinds this build doesn't know.
    private func drainLines() -> Bool {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = buffer[buffer.index(after: newlineIndex)...]
            guard !lineData.isEmpty else { continue }
            do {
                let response: LLMWireResponse = try LLMWire.decode(Data(lineData))
                responses.append(response)
                if response.type == .done || response.type == .error {
                    finish(.success(responses))
                    return true
                }
                // `status` is terminal too — the server answers and closes.
                if response.type == .status {
                    finish(.success(responses))
                    return true
                }
            } catch {
                NSLog("[DictatorMeetings] Skipping undecodable line from Dictator: \(error.localizedDescription)")
            }
        }
        return false
    }

    /// External teardown (Swift `Task` cancellation). Safe to call at any
    /// point, including before the continuation is stored.
    fileprivate func abort(with error: Error) {
        queue.async { self.finish(.failure(error)) }
    }

    /// Resumes the continuation exactly once and tears the connection down.
    /// Must be called on `queue`.
    private func finish(_ result: Result<[LLMWireResponse], Error>) {
        guard !finished else { return }
        finished = true
        if continuation == nil, case .failure(let error) = result { earlyFailure = error }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
