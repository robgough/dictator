import Foundation

/// Why a scheduled LLM job didn't produce a result. Distinct from an engine
/// error: both of these mean "the model was fine, the timing wasn't".
enum LLMSchedulerError: LocalizedError, Sendable {
    /// A `.interactive` job arrived while this `.background` one was generating,
    /// so it was cancelled at the next token. Retry shortly.
    case preempted
    /// Another `.background` job is already running. Only one is allowed at a
    /// time — the model is a single serialised container, and queueing a second
    /// remote request behind a slow one just hides the wait.
    case busy

    var errorDescription: String? {
        switch self {
        case .preempted: return "The model was needed for dictation and this job was stopped."
        case .busy:      return "The model is already busy with another background job."
        }
    }
}

/// Arbitrates access to the in-process LLM between the local user and everything
/// else.
///
/// There is exactly one loaded model per process and `ModelContainer.perform`
/// serialises calls into it, so the only real question is *who waits*. The
/// answer is never the person holding a hotkey down: a dictation must not sit
/// behind a five-minute meeting summary. So:
///
/// - `.interactive` (dictation passes, Assistant Mode, Settings → Models
///   "Verify") cancels any running background job and then runs inline, in the
///   caller's own task. Inline matters: the pipeline's cancellation story
///   already relies on `Task.isCancelled` being the *caller's* task, so wrapping
///   must not move the work into a different one.
/// - `.background` (today: requests arriving over the LLM socket from Dictator
///   Meetings) runs inside its own `Task` so it can be cancelled independently.
///   MLX generation checks `Task.isCancelled` in its `didGenerate` callback and
///   returns `.stop` at the next token, so cancelling the task ends the
///   generation within a token rather than at the end of the reply.
///
/// The interactive path deliberately does not *wait* for the cancelled
/// background job to unwind. It doesn't need to: `ModelContainer.perform` hands
/// the container over as soon as the stopped generation returns, which is one
/// token away.
///
/// Both apps compile this file (it lives in `Sources/DictatorMac`), so each
/// process arbitrates its own engine. There is no cross-process scheduling —
/// that's what the socket's single-background-job rule is for.
@MainActor
final class LLMScheduler {
    static let shared = LLMScheduler()

    enum Priority: Sendable {
        case interactive
        case background
    }

    /// Cancels the in-flight background job, if any. Type-erased because the
    /// job's result type varies per call.
    private var cancelBackgroundJob: (() -> Void)?

    /// True from the moment a background job is admitted until its `run` call
    /// returns. Guards the "one background job at a time" rule.
    private(set) var busy: Bool = false

    private init() {}

    /// Runs `body` under the given priority. Throws whatever `body` throws, or
    /// `LLMSchedulerError.preempted` / `.busy`.
    ///
    /// `T` is constrained to `Sendable` because the background path carries the
    /// result out of a `Task`. Every caller returns `String`, `AssistantResult`
    /// or `Void`, all of which qualify.
    func run<T: Sendable>(_ priority: Priority,
                          _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        switch priority {
        case .interactive:
            // Stop the background generation first so the container frees up
            // while we're still setting up the interactive call.
            cancelBackground()
            return try await body()

        case .background:
            guard !busy else { throw LLMSchedulerError.busy }
            busy = true
            let job = Task<T, Error> { @MainActor in
                let value = try await body()
                // MLX's cancellation is cooperative: a cancelled generation
                // returns the tokens it managed rather than throwing. Without
                // this check a preempted job would deliver a truncated reply as
                // if it were complete.
                try Task.checkCancellation()
                return value
            }
            cancelBackgroundJob = { job.cancel() }
            defer {
                busy = false
                cancelBackgroundJob = nil
            }
            do {
                return try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
            } catch is CancellationError {
                throw LLMSchedulerError.preempted
            }
        }
    }

    /// Cancels the running background job, if any. Safe to call when there
    /// isn't one. Exposed so a caller that is about to tear the engine down
    /// (unload, model switch, app quit) can stop generation without pretending
    /// to be an interactive job.
    func cancelBackground() {
        cancelBackgroundJob?()
    }
}
