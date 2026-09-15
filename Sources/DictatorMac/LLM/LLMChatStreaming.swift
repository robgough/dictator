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

    static func system(_ content: String) -> Self { .init(role: .system, content: content) }
    static func user(_ content: String) -> Self { .init(role: .user, content: content) }

    /// The dictionary the Jinja template sees.
    var templateMessage: [String: any Sendable] {
        var message: [String: any Sendable] = ["role": role.rawValue, "content": content]
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
}

/// Streaming deltas, in order.
enum ChatStreamDelta: Sendable {
    case chunk(String)
    case toolCall(ChatWireToolCall)
}

/// Opt-in refinement for engines that can run a streaming, tool-calling chat
/// turn.
///
/// Separate from `LLMEngine` for the same reason `LLMUsageReporting` is:
/// `AppleFoundationLLMService` can't do this (its framework has its own tool
/// protocol and a context window well below the bar), and widening `LLMEngine`
/// would force it to carry a method it can only throw from. `MLXLLMService`
/// conforms; the chat UI refuses to open on an engine that doesn't.
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
