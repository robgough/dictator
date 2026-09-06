import Foundation

/// Shared HTTP plumbing for the cloud providers.
///
/// Two things here are load-bearing and easy to get wrong:
///
/// 1. **Timeouts.** A final-notes request on a two-hour meeting is a 60k-token
///    prompt; a frontier model can spend several minutes on it before the first
///    byte comes back. `URLSession`'s 60-second default kills those requests
///    right at the point the user cares most, so the request timeout is 600 s.
/// 2. **Cancellation.** Every call polls the caller's `cancellation` closure
///    and cancels the underlying `URLSessionTask`, as well as honouring Swift
///    `Task` cancellation. Stopping or deleting a meeting must actually stop
///    the upload, not just abandon the `await`.
enum CloudHTTP {
    /// One session for every cloud provider. Reused so connections are pooled
    /// across the many passes of a single post-meeting run.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Long enough for a 60k-token prompt on a slow model. The per-resource
        // ceiling is higher again so a genuinely long generation isn't cut off
        // after the headers arrive.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1_200
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        // Transcripts are the user's private conversations: never let the URL
        // loading system write them (or the replies) into a disk cache.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "DictatorMeetings/\(version)"
    }

    struct Response: Sendable {
        let status: Int
        let data: Data

        var isSuccess: Bool { (200...299).contains(status) }

        /// Best-effort human-readable error text out of the two shapes both
        /// vendors use (`{"error": {"message": …}}` and `{"error": "…"}`),
        /// falling back to the raw body so a self-hosted server's plain-text
        /// error still reaches the user.
        var errorMessage: String {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = object["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return message
                }
                if let error = object["error"] as? String { return error }
                if let message = object["message"] as? String { return message }
            }
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return String(raw.prefix(400))
        }
    }

    /// One request, no retry. Throws `.cancelled` the moment either
    /// cancellation channel trips.
    static func send(_ request: URLRequest,
                     cancellation: @Sendable @escaping () -> Bool) async throws -> Response {
        try MeetingLLMCancellation.check(cancellation)
        let call = CancellableHTTPCall()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.start(request: request, cancellation: cancellation, continuation: continuation)
            }
        } onCancel: {
            call.abort(with: MeetingLLMError.cancelled)
        }
    }

    /// `send` plus the retry policy every cloud provider wants: 429 and 5xx are
    /// transient, so try up to `maxAttempts` times with exponential backoff
    /// (1 s, 2 s, 4 s), honouring a `Retry-After` header when the server sends
    /// one. 4xx other than 429 is a configuration problem and fails
    /// immediately — retrying a 401 three times just makes the user wait.
    static func sendWithRetry(_ request: URLRequest,
                              providerName: String,
                              maxAttempts: Int = 3,
                              cancellation: @Sendable @escaping () -> Bool) async throws -> Response {
        var attempt = 1
        var lastError: Error?
        while attempt <= maxAttempts {
            try MeetingLLMCancellation.check(cancellation)
            do {
                let response = try await send(request, cancellation: cancellation)
                if response.isSuccess { return response }
                let retryable = response.status == 429 || (500...599).contains(response.status)
                guard retryable, attempt < maxAttempts else { return response }
                let wait = retryAfterSeconds(response) ?? backoffSeconds(attempt)
                NSLog("[DictatorMeetings] \(providerName) HTTP \(response.status) — retry \(attempt)/\(maxAttempts - 1) in \(wait)s")
                try await sleep(seconds: wait, cancellation: cancellation)
            } catch let error as MeetingLLMError {
                // `.cancelled` is the user, never a flake — never retry it.
                if case .cancelled = error { throw error }
                lastError = error
                guard attempt < maxAttempts else { throw error }
                try await sleep(seconds: backoffSeconds(attempt), cancellation: cancellation)
            }
            attempt += 1
        }
        throw lastError ?? MeetingLLMError.transport("\(providerName) didn't respond.")
    }

    private static func backoffSeconds(_ attempt: Int) -> Double {
        min(30, pow(2, Double(attempt - 1)))
    }

    private static func retryAfterSeconds(_ response: Response) -> Double? {
        // The header isn't reachable from `Response`; the vendors also put a
        // hint in the body for rate limits, so parse that when present.
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let seconds = error["retry_after"] as? Double
        else { return nil }
        return min(30, max(0, seconds))
    }

    /// Cancellation-aware sleep, so a user stopping a meeting doesn't wait out
    /// a 30-second rate-limit backoff.
    private static func sleep(seconds: Double, cancellation: @Sendable @escaping () -> Bool) async throws {
        var remaining = seconds
        while remaining > 0 {
            try MeetingLLMCancellation.check(cancellation)
            let step = min(0.2, remaining)
            try await Task.sleep(for: .seconds(step))
            remaining -= step
        }
        try MeetingLLMCancellation.check(cancellation)
    }
}

/// One `URLSessionDataTask` wrapped in a continuation, with a poller that
/// cancels the task when the caller's closure says to stop.
///
/// `@unchecked Sendable`: every mutable field is only ever touched on `queue`,
/// and the continuation is resumed exactly once (guarded by `finished`).
private final class CancellableHTTPCall: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.robgough.DictatorMeetings.cloud-http")
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<CloudHTTP.Response, Error>?
    private var finished = false
    /// Set when the call is aborted before `start` stored its continuation —
    /// `withTaskCancellationHandler` can fire `onCancel` before the body runs.
    private var earlyFailure: Error?

    func start(request: URLRequest,
               cancellation: @Sendable @escaping () -> Bool,
               continuation: CheckedContinuation<CloudHTTP.Response, Error>) {
        queue.async { [self] in
            if self.finished {
                continuation.resume(throwing: self.earlyFailure ?? MeetingLLMError.cancelled)
                return
            }
            self.continuation = continuation

            let task = CloudHTTP.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        let nsError = error as NSError
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                            self.finish(.failure(MeetingLLMError.cancelled))
                        } else {
                            self.finish(.failure(MeetingLLMError.transport(error.localizedDescription)))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        self.finish(.failure(MeetingLLMError.transport("The service returned no HTTP response.")))
                        return
                    }
                    self.finish(.success(CloudHTTP.Response(status: http.statusCode, data: data ?? Data())))
                }
            }
            self.task = task
            task.resume()
            self.poll(cancellation)
        }
    }

    private func poll(_ cancellation: @Sendable @escaping () -> Bool) {
        queue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, !self.finished else { return }
            if cancellation() {
                self.finish(.failure(MeetingLLMError.cancelled))
                return
            }
            self.poll(cancellation)
        }
    }

    func abort(with error: Error) {
        queue.async { self.finish(.failure(error)) }
    }

    /// Resumes exactly once and always cancels the URL task, so an abandoned
    /// request stops uploading rather than running to completion in the
    /// background.
    private func finish(_ result: Result<CloudHTTP.Response, Error>) {
        guard !finished else { return }
        finished = true
        if continuation == nil, case .failure(let error) = result { earlyFailure = error }
        task?.cancel()
        task = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
