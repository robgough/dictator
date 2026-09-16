import Foundation
import MLXLMCommon

/// One message in the raw chat-template shape.
///
/// Deliberately *not* `MLXLMCommon.Chat.Message`. That type is
/// `(role, content, images, videos)` — there is nowhere to put a tool call —
/// and `ToolCallProcessor` strips the call out of the generated text, so by the
/// time we'd re-render a previous turn the call is gone. Two consequences,
/// both measured (`scratch/tool-call-check`):
///
/// - Qwen 3.5 survives it. Its template renders any `role: tool` message inside
///   `<tool_response>` tags unconditionally.
/// - **Gemma 4 does not.** Its template emits a tool response only by
///   forward-scanning consecutive `role: tool` messages *from an assistant
///   message that carries `tool_calls`*. With no `tool_calls` key, the result
///   renders as nothing at all — so the model never sees it and calls the same
///   tool again, forever. Both Gemma 4 sizes looped on every tool scenario
///   until this shape was used, then passed all of them.
///
/// `UserInput(messages:)` hands these dictionaries to the template verbatim,
/// which is what Python mlx-lm does and what both templates document. As a
/// bonus it's `Sendable` — `Chat.Message` is not, and can't cross
/// `ModelContainer.perform`'s boundary at all.
struct ChatWireMessage: Sendable {
    enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    var role: Role
    var content: String
    /// Set on an assistant message that asked for tools.
    var toolCalls: [ChatWireToolCall] = []
    /// Set on a tool message, matching the call it answers.
    var toolCallID: String?
    var toolName: String?
    /// Images this message carries, as file paths.
    ///
    /// Paths rather than `CGImage` because `ChatWireMessage` is `Sendable` and
    /// crosses `ModelContainer.perform`, which `CGImage` and `CIImage` cannot.
    /// Each engine loads them at its own boundary; decoding a PNG is
    /// milliseconds against an encode measured in seconds.
    ///
    /// Empty for every message whose images have been demoted to their stored
    /// description — see `ChatEngine.renderForModel`. A message never carries
    /// both: paying to encode the pixels and then also telling the model what
    /// they say is the worst of both.
    var imagePaths: [String] = []

    static func system(_ content: String) -> Self { .init(role: .system, content: content) }
    static func user(_ content: String) -> Self { .init(role: .user, content: content) }

    /// The dictionary the Jinja template sees.
    var templateMessage: [String: any Sendable] {
        var message: [String: any Sendable] = ["role": role.rawValue, "content": content]
        // A message carrying images needs the *structured* content list the VLM
        // message generators emit — images first, then the text — not a plain
        // string. `UserInput(messages:)` hands these dicts to the template
        // untouched (only the typed `chat:` path rewrites them), so with a plain
        // string the template emits no image placeholder and `prepare` throws
        // "Number of placeholder tokens does not match number of frames".
        //
        // Measured in `scratch/mlx-image-dicts-check` on Qwen 3.5 9B: plain
        // string throws, this shape reads the image correctly and produces the
        // same 431-token prompt as the typed API — with a tool advertised, and
        // with a later text-only turn after it.
        //
        // Only the image-bearing message is converted. Gemma 4's generator keeps
        // `system` as a plain string, so converting everything would break it.
        if !imagePaths.isEmpty {
            message["content"] = imagePaths.map { _ in ["type": "image"] }
                + [["type": "text", "text": content]]
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { call -> [String: any Sendable] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        // Templates iterate `arguments | items`, so this has to
                        // be a mapping — a JSON *string* renders as garbage.
                        "arguments": call.arguments.sendableValue,
                    ] as [String: any Sendable],
                ]
            }
        }
        if let toolCallID { message["tool_call_id"] = toolCallID }
        if let toolName { message["name"] = toolName }
        return message
    }
}

/// A tool call, in the form that survives persistence and the approval UI.
struct ChatWireToolCall: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: MCPJSON

    init(id: String = UUID().uuidString, name: String, arguments: MCPJSON) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Arguments rendered for the approval sheet and the transcript. Users are
    /// told to check what a tool is about to be called with, so this has to be
    /// readable, not a blob.
    var argumentSummary: String {
        guard case .object(let fields) = arguments, !fields.isEmpty else { return "" }
        return fields.keys.sorted()
            .map { "\($0): \(fields[$0]?.compactString ?? "")" }
            .joined(separator: ", ")
    }
}

/// How fast a round ran.
///
/// Stored as counts and seconds rather than as rates, so the two halves of
/// each rate are written down together and can only ever be divided by the
/// thing that was actually measured. (A rate whose numerator and denominator
/// came from different populations is how the usage pane once reported
/// 33,116 words per minute.)
struct ChatRoundSpeed: Codable, Hashable, Sendable {
    var generatedTokens: Int
    /// Time spent generating those tokens, with the first one excluded — the
    /// token loop restarts its clock once the first token is out, so this is a
    /// decode rate and doesn't include waiting for prefill.
    var generationSeconds: Double
    /// Tokens prefilled this round. Usually far short of the whole prompt:
    /// `ChatPromptCache` keeps the rest between the rounds of a turn.
    var prefilledTokens: Int
    var prefillSeconds: Double

    /// Tokens per second while generating, or nil when there wasn't enough of
    /// a reply to say.
    ///
    /// Short replies are excluded rather than reported: with the first token
    /// outside the measured window, a four-token answer divides four tokens by
    /// the time three of them took, and the shorter the reply the more that
    /// flatters it.
    var tokensPerSecond: Double? {
        rate(Double(generatedTokens), over: generationSeconds, floor: 8)
    }

    /// Tokens per second while prefilling. Nil on a round that was fully
    /// cached, which is a real and common outcome — not a measurement failure.
    var prefillTokensPerSecond: Double? {
        rate(Double(prefilledTokens), over: prefillSeconds, floor: 8)
    }

    private func rate(_ tokens: Double, over seconds: Double, floor: Double) -> Double? {
        guard tokens >= floor, seconds > 0 else { return nil }
        let value = tokens / seconds
        return value.isFinite ? value : nil
    }
}

/// What one round of generation produced.
struct ChatRoundResult: Sendable {
    /// Prose the model emitted, already cleaned. Empty when it went straight
    /// to a tool call.
    let text: String
    /// Tool calls parsed out of the stream. More than one is normal — both Qwen
    /// models issue two calls in a single round when a question needs two tools.
    let toolCalls: [ChatWireToolCall]
    let promptTokens: Int
    let completionTokens: Int
    /// True when generation stopped because it hit the token cap rather than
    /// finishing. The UI says so instead of presenting a truncated answer as
    /// complete.
    let hitTokenLimit: Bool
    /// How fast it ran. Nil when the round produced no `.info` to measure —
    /// a round cancelled before its first token, in practice.
    let speed: ChatRoundSpeed?
}

/// Streaming deltas, in order.
enum ChatStreamDelta: Sendable {
    case chunk(String)
    case toolCall(ChatWireToolCall)
}

/// Opt-in refinement for engines that can run a streaming, tool-calling chat
/// turn.
///
/// Separate from `LLMEngine` for the same reason `LLMUsageReporting` is: not
/// every engine can run a chat turn, and widening `LLMEngine` would force the
/// ones that can't to carry a method they could only throw from. The chat UI
/// refuses to open on an engine that doesn't conform.
///
/// Both engines conform, but they mean different things by it.
/// `MLXLLMService` does the whole job — streaming prose *and* tool calls, which
/// is what makes `ChatEngine`'s loop a loop. `AppleFoundationLLMService` never
/// emits a tool call, so its turns are always a single round; see the
/// extension on it for why its framework's tool protocol isn't reachable from
/// a runtime JSON schema.
@MainActor
protocol LLMChatStreaming: AnyObject {
    /// Runs one generation round: prompt → prose and/or tool calls.
    ///
    /// Deliberately one *round*, not the whole agent loop. The loop belongs to
    /// the caller, which owns tool dispatch, user approval and persistence —
    /// and which needs to be able to re-run a round verbatim after dictation
    /// preempts it.
    /// `cacheOwner` identifies the conversation this round belongs to, so
    /// prefill state can be reused across the rounds of a turn and dropped when
    /// the user switches thread. Any stable per-thread string will do.
    func streamChatRound(
        messages: [ChatWireMessage],
        tools: [ToolSpec],
        maxTokens: Int,
        cacheOwner: String,
        onDelta: @MainActor @escaping (ChatStreamDelta) -> Void
    ) async throws -> ChatRoundResult
}
