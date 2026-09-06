import Foundation

/// The one surface every note-writing backend presents to the meetings code.
///
/// Deliberately much smaller than `LLMEngine` (which the dictation pipeline
/// drives): meetings only ever need "here's a system prompt and a big user
/// message, give me text back". Everything else the old code reached for —
/// `format`, `runPass`, conversation summarisation, the token budget — was
/// either dictation-only or is now the caller's job (`MeetingSummaryService`
/// chunks against `contextWindowTokens`).
///
/// Implementations are reference types held by `ProviderRegistry` so a warm
/// connection / loaded model survives between passes.
@MainActor
protocol MeetingLLM: AnyObject {
    /// The `ProviderConfig.id` this instance was built from. Registry cache
    /// key; also what `KeychainStore` uses as the account name.
    var id: String { get }

    /// The user's label for this provider, for HUD lines and error messages.
    var displayName: String { get }

    /// True when nothing leaves the Mac. Drives the privacy copy and lets
    /// `MeetingSession.reclaimAfterProcessing` decide whether there's GPU
    /// state worth releasing.
    var isLocal: Bool { get }

    /// Tokens the model can take in one request, prompt AND reply. Meetings'
    /// chunker sizes its map-reduce windows off this, so a wrong value is
    /// either wasted passes or a rejected request — see `CloudModelLimits`.
    var contextWindowTokens: Int { get }

    /// Largest reply this provider will produce in one request. Anthropic
    /// *requires* the caller to state it; OpenAI treats it as a cap.
    var maxOutputTokens: Int { get }

    /// Bring the provider to a state where `complete` will work: load the
    /// model, open the socket, check the key is present. Cheap and idempotent
    /// once ready — callers may invoke it before every pass.
    func prepare() async throws

    /// One completion. `temperature` is honoured by every backend — the
    /// Dictator socket forwards it over the wire, and both in-process
    /// providers pass it to `LLMEngine.complete`.
    ///
    /// `cancellation` is polled throughout — every implementation must both
    /// respect it and honour Swift `Task` cancellation, because a meeting can
    /// be stopped, deleted or superseded mid-generation.
    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String

    /// Round-trips a minimal request and returns the model id that actually
    /// answered. Drives the Providers tab's "Test" button and status dot.
    func healthCheck() async throws -> String
}

/// Errors every provider can raise. Each case carries text the Settings UI and
/// the meeting HUD can show verbatim — small local models and cloud 401s fail
/// for very different reasons and the user needs to know which.
enum MeetingLLMError: LocalizedError {
    /// The backend exists but can't serve right now (Dictator not running,
    /// Apple Intelligence off, model not downloaded).
    case unavailable(String)
    /// No API key in the Keychain for a provider that needs one.
    case missingKey(String)
    /// Misconfigured — no base URL, unparseable URL, no model id.
    case badConfiguration(String)
    /// The remote returned a non-2xx status we couldn't retry past.
    case http(status: Int, message: String)
    /// The response parsed but carried no usable text.
    case emptyResponse(String)
    /// Cancelled by the caller's `cancellation` closure or by `Task`
    /// cancellation. Callers treat this as "the user stopped it", not a
    /// failure to report.
    case cancelled
    /// Transport / decoding failure with the underlying description.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let m):      return m
        case .missingKey(let name):    return "No API key saved for \(name). Add one on the Providers tab."
        case .badConfiguration(let m): return m
        case .http(let status, let m):
            if m.isEmpty { return "The service replied with HTTP \(status)." }
            return "The service replied with HTTP \(status): \(m)"
        case .emptyResponse(let name):  return "\(name) returned an empty reply."
        case .cancelled:                return "Cancelled."
        case .transport(let m):         return m
        }
    }
}

extension MeetingLLM {
    /// The meetings' equivalent of `LLMEngine.assist(...)`: an instruction plus
    /// an optional chunk of selected text, answered with a `MODE:
    /// REPLACE`/`DRAFT` marker the notes UI uses to decide where the reply
    /// goes.
    ///
    /// The prompt shape is copied from `MLXLLMService.assist` on purpose —
    /// same `LLMTextUtilities.renderAssistantUserMessage` block, same
    /// `parseAssistant` post-processing, same 0.2 temperature — so pointing a
    /// meeting at the local MLX provider produces byte-identical requests to
    /// what the old in-Dictator path sent. The only differences are that
    /// meetings never carry prior turns or a compaction summary (each ask is
    /// standalone), and the reply cap is `min(maxOutputTokens, 4096)` rather
    /// than MLX's flat 8192 — a notes answer is a paragraph or a rewritten
    /// section, and 4096 tokens keeps a mis-steered cloud model from billing
    /// for an essay.
    func assist(selection: String?,
                instruction: String,
                systemPrompt: String,
                cancellation: @Sendable @escaping () -> Bool) async throws -> AssistantResult {
        let user = LLMTextUtilities.renderAssistantUserMessage(selection: selection, instruction: instruction)
        let raw = try await complete(
            system: systemPrompt,
            user: user,
            maxTokens: min(maxOutputTokens, 4096),
            temperature: 0.2,
            cancellation: cancellation
        )
        return LLMTextUtilities.parseAssistant(raw)
    }

    /// Convenience for the many meeting call sites that have no cancellation
    /// source of their own but still want `Task` cancellation to work.
    func assist(selection: String?,
                instruction: String,
                systemPrompt: String) async throws -> AssistantResult {
        try await assist(selection: selection,
                         instruction: instruction,
                         systemPrompt: systemPrompt,
                         cancellation: { Task.isCancelled })
    }

    /// Plain completion with the common defaults (temperature 0, `Task`
    /// cancellation), for the deterministic passes — speaker naming, the
    /// live-notes diff, the coach report.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system,
                           user: user,
                           maxTokens: maxTokens,
                           temperature: 0,
                           cancellation: { Task.isCancelled })
    }
}

/// Shared cancellation helper. Every provider polls both the caller's closure
/// and `Task.isCancelled`, so this is the single place that decides what
/// "stop" means.
enum MeetingLLMCancellation {
    static func check(_ cancellation: @Sendable () -> Bool) throws {
        if Task.isCancelled || cancellation() { throw MeetingLLMError.cancelled }
    }

    static func isCancelled(_ cancellation: @Sendable () -> Bool) -> Bool {
        Task.isCancelled || cancellation()
    }

    /// Runs `body` in a child task that is cancelled as soon as `cancellation`
    /// returns true (polled every 200 ms) or the calling task is cancelled.
    ///
    /// This is how the in-process providers honour `cancellation`: neither
    /// `LLMEngine.complete` nor Apple's `LanguageModelSession` takes a
    /// cancellation closure, but MLX generation checks `Task.isCancelled`
    /// between tokens (`didGenerate` → `.stop`), so cancelling the task is
    /// exactly the "stop at the next token" behaviour the meeting HUD wants.
    static func runCancellable<T: Sendable>(
        _ cancellation: @Sendable @escaping () -> Bool,
        body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try check(cancellation)
        let work = Task { @MainActor in try await body() }
        let watchdog = Task {
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return  // the watchdog itself was cancelled — work finished
                }
                if cancellation() {
                    work.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError {
            throw MeetingLLMError.cancelled
        } catch {
            // MLX stops mid-generation on cancellation and returns whatever it
            // had rather than throwing, so an error here is a real failure —
            // unless the caller has since asked us to stop.
            if isCancelled(cancellation) { throw MeetingLLMError.cancelled }
            throw error
        }
    }
}
