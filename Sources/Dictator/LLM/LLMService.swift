import Foundation
import Hub
import MLXLLM
import MLXLMCommon

@MainActor
final class LLMService {
    private var currentModelID: String?
    private var container: ModelContainer?

    func ensureLoaded(modelID: String, progress: (@Sendable @MainActor (Double) -> Void)? = nil) async throws {
        if currentModelID == modelID, container != nil { return }
        container = nil
        currentModelID = nil

        let hub = HubApi(downloadBase: ModelStorage.llmRoot())
        let configuration = ModelConfiguration(id: modelID)

        let loaded = try await LLMModelFactory.shared.loadContainer(
            hub: hub,
            configuration: configuration
        ) { p in
            let fraction = p.fractionCompleted
            Task { @MainActor in progress?(fraction) }
        }
        container = loaded
        currentModelID = modelID
    }

    /// Drop the in-memory MLX container. Called before deleting the model
    /// files from disk so we don't tear them out from under a live container
    /// that has them mmap'ed.
    func unload(modelID: String) {
        guard currentModelID == modelID else { return }
        container = nil
        currentModelID = nil
    }

    /// Optional grammar tidying pass. Allowed to make small grammar fixes; the caller
    /// validates by word-level edit distance and discards the result if it drifts too far.
    func tidyGrammar(text: String, modelID: String, systemPrompt: String) async throws -> String {
        try await format(text: text, modelID: modelID, systemPrompt: systemPrompt)
    }

    /// Structural rewrite. Adds paragraph/list structure without touching the
    /// words. The caller is responsible for verifying the word sequence is preserved.
    func restructure(text: String, modelID: String, systemPrompt: String) async throws -> String {
        try await format(text: text, modelID: modelID, systemPrompt: systemPrompt)
    }

    func format(text: String, modelID: String, systemPrompt: String) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        let prompt = systemPrompt
        // Wrap the transcript in `<<< >>>` so the model treats it as data, not a
        // question or instruction. Without this signal, small models slip into
        // "helpful assistant" mode and answer the user. The `Input:/Output:` labels
        // we used previously caused the model to echo the wrapping back — the
        // post-processor in clean() handles any residual echo defensively.
        let userText = "<<<\n\(text)\n>>>"

        let raw = try await container.perform { (ctx: ModelContext) -> String in
            let userInput = UserInput(chat: [
                .system(prompt),
                .user(userText)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            // Tight output cap. A correctly-formatted version is almost always
            // close to the input length; anything substantially longer is the
            // model writing a chat-style answer for question-shaped dictations.
            // Cap = 1.25x input tokens + a small headroom (room for punctuation /
            // emoji expansion). The floor of 24 keeps single-word dictations from
            // being silently truncated.
            let approxInputTokens = max(8, text.count / 4)
            let maxTokens = min(768, max(24, Int(Double(approxInputTokens) * 1.25) + 8))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0, topP: 1.0)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in .more }
            )
            return result.output
        }

        return Self.clean(raw)
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading echoed block like `<<<\n...\n>>>` (possibly with surrounding lines).
        if s.hasPrefix("<<<"), let endRange = s.range(of: ">>>") {
            s = String(s[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip a leading "Output:" / "OUTPUT:" / "Formatted:" label.
        for label in ["Output:", "OUTPUT:", "output:", "Formatted:", "FORMATTED:"] {
            if s.hasPrefix(label) {
                s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Strip a markdown code-fence wrapper if the model decided to wrap the output.
        if s.hasPrefix("```"), let firstNL = s.firstIndex(of: "\n") {
            let body = String(s[s.index(after: firstNL)...])
            if body.hasSuffix("```") {
                s = String(body.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip a single pair of wrapping quotes/backticks.
        if s.count >= 2 {
            let first = s.first!, last = s.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "`" && last == "`") {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}
