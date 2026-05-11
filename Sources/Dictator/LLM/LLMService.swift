import Foundation
import Hub
import MLXLLM
import MLXLMCommon

enum AssistantMode: String, Sendable {
    case replace
    case draft
}

struct AssistantResult: Sendable {
    let mode: AssistantMode
    let text: String
}

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
        // Grammar fixes don't grow the text — same cap shape as the formatter pass.
        try await runFormatPass(text: text, modelID: modelID, systemPrompt: systemPrompt,
                                maxTokenMultiplier: 1.20, maxTokenConstant: 8)
    }

    /// Structural rewrite. Adds paragraph/list structure without touching the
    /// words. The caller is responsible for verifying the word sequence is preserved.
    func restructure(text: String, modelID: String, systemPrompt: String) async throws -> String {
        // Structure pass legitimately *adds* tokens — bullet markers ("- "), blank
        // lines for paragraphs, numbered prefixes — even though no words change.
        // Give it a much more generous cap so a long dictation can be bulleted
        // without getting truncated mid-list. The word-sequence equality check in
        // Pipeline.maybeRestructure() is what enforces correctness here.
        try await runFormatPass(text: text, modelID: modelID, systemPrompt: systemPrompt,
                                maxTokenMultiplier: 1.60, maxTokenConstant: 32)
    }

    func format(text: String, modelID: String, systemPrompt: String) async throws -> String {
        // Tight cap on the formatter — a correctly formatted version is almost
        // always within ~15% of the input length. The real defense against the
        // "model answered the question" failure mode is the word-count growth
        // check in Pipeline.passOnePreservesContent(); the cap here is just a
        // belt-and-braces perf optimisation so a wandering model doesn't generate
        // an entire essay before we reject it.
        try await runFormatPass(text: text, modelID: modelID, systemPrompt: systemPrompt,
                                maxTokenMultiplier: 1.20, maxTokenConstant: 8)
    }

    private func runFormatPass(text: String, modelID: String, systemPrompt: String,
                               maxTokenMultiplier: Double, maxTokenConstant: Int) async throws -> String {
        try await ensureLoaded(modelID: modelID)
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        // Wrap the transcript in `<<< >>>` so the model treats it as data, not a
        // question or instruction. Without this signal, small models slip into
        // "helpful assistant" mode and answer the user. The `Input:/Output:` labels
        // we used previously caused the model to echo the wrapping back — the
        // post-processor in clean() handles any residual echo defensively.
        let userText = "<<<\n\(text)\n>>>"

        let raw = try await container.perform { (ctx: ModelContext) -> String in
            let userInput = UserInput(chat: [
                .system(systemPrompt),
                .user(userText)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            let approxInputTokens = max(8, text.count / 4)
            let maxTokens = min(2048,
                                max(24,
                                    Int(Double(approxInputTokens) * maxTokenMultiplier) + maxTokenConstant))
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

    /// Assistant Mode: takes an optional snippet of text the user had selected plus
    /// a spoken instruction about what to do. The model classifies its own reply as
    /// either REPLACE (transform-in-place / insert-at-cursor) or DRAFT (clipboard-only
    /// output). When the classifier marker is missing or malformed, we default to
    /// .draft — non-destructive. Selection may be nil (user had nothing selected
    /// and wants something generated, e.g. "make me a list of 10 things here").
    func assist(selection: String?, instruction: String, modelID: String, systemPrompt: String) async throws -> AssistantResult {
        try await ensureLoaded(modelID: modelID)
        guard let container else {
            throw NSError(domain: "Dictator", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
        }

        let selectionBlock: String
        if let selection, !selection.isEmpty {
            selectionBlock = """
            SELECTION:
            <<<
            \(selection)
            >>>
            """
        } else {
            selectionBlock = "SELECTION: (none — the user has nothing selected)"
        }
        let userText = """
        \(selectionBlock)

        INSTRUCTION:
        <<<
        \(instruction)
        >>>
        """

        let raw = try await container.perform { (ctx: ModelContext) -> String in
            let userInput = UserInput(chat: [
                .system(systemPrompt),
                .user(userText)
            ])
            let lmInput = try await ctx.processor.prepare(input: userInput)
            // Assistant Mode is free-form generation — the user's instruction governs
            // length ("give me 100 emojis", "draft a long email"). The cap here is
            // purely a runaway-generation guard, not a length policy, so it's set
            // generously. 8192 tokens ≈ ~6000 words, comfortably above any reasonable
            // single dictation-driven request while still bounding pathological loops.
            // RAM cost is paid only when generation actually reaches the cap (MLX
            // grows the KV cache on demand); worst case ≈ 1 GB on a typical 3B model.
            let params = GenerateParameters(maxTokens: 8192, temperature: 0.2, topP: 0.95)
            let result = try MLXLMCommon.generate(
                input: lmInput,
                parameters: params,
                context: ctx,
                didGenerate: { (_: [Int]) in .more }
            )
            return result.output
        }

        return Self.parseAssistant(raw)
    }

    /// Strips the `MODE: REPLACE`/`MODE: DRAFT` first-line marker the assistant prompt
    /// asks the model to emit, and returns the body. Falls back to `.draft` (the safer
    /// default — clipboard-only, non-destructive) if the marker is missing or unrecognised.
    static func parseAssistant(_ raw: String) -> AssistantResult {
        let cleaned = clean(raw)
        // Look for `MODE: X` at the start of any of the first few lines — small models
        // sometimes wrap the response in extra blank lines or quotes before the marker.
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.prefix(3).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("MODE:") {
                let suffix = upper.dropFirst("MODE:".count).trimmingCharacters(in: .whitespaces)
                let mode: AssistantMode
                if suffix.hasPrefix("REPLACE") { mode = .replace }
                else if suffix.hasPrefix("DRAFT") { mode = .draft }
                else { mode = .draft }
                let bodyLines = lines.dropFirst(idx + 1)
                let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return AssistantResult(mode: mode, text: stripAssistantPreamble(body))
            }
        }
        return AssistantResult(mode: .draft, text: stripAssistantPreamble(cleaned))
    }

    /// Small local models almost always sneak in a meta preamble ("Sure! Here's the
    /// email you asked for:" / "Of course, here is a draft:") even when the prompt
    /// explicitly forbids it. We strip them defensively — only when they appear as
    /// their own line followed by actual content, so we never accidentally chop a
    /// legitimate single-line answer that happens to start with "Here is...".
    static func stripAssistantPreamble(_ s: String) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // If the entire output is one line, it IS the content — never strip.
        guard lines.count > 1 else { return s }

        var keepGoing = true
        while keepGoing, lines.count > 1 {
            keepGoing = false
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            if first.isEmpty {
                lines.removeFirst()
                keepGoing = true
                continue
            }
            if isPreambleLine(first) {
                lines.removeFirst()
                keepGoing = true
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let standaloneAffirmations: Set<String> = [
        "sure", "of course", "certainly", "absolutely",
        "got it", "no problem", "okay", "ok", "yes", "alright"
    ]

    private static let preamblePrefixes: [String] = [
        "here's", "here is", "here are", "here you go",
        "sure, here", "sure! here", "sure here",
        "of course, here", "of course! here",
        "certainly, here", "absolutely, here",
        "below is", "below are",
        "i've drafted", "i have drafted",
        "i'll draft", "i'll write", "i've written", "i have written",
        "i'll give", "i can give"
    ]

    private static func isPreambleLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let stripped = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".!,;:"))
        if standaloneAffirmations.contains(stripped) { return true }
        // Meta preamble lines end with a colon or period (the content follows on the
        // next line). Without that, the line might be a legitimate sentence that just
        // happens to start with "Here is".
        let endsWithIntroducer = lower.hasSuffix(":") || lower.hasSuffix(".") || lower.hasSuffix("…") || lower.hasSuffix("...")
        guard endsWithIntroducer else { return false }
        return preamblePrefixes.contains(where: lower.hasPrefix)
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading echoed block like `<<<\n...\n>>>` (possibly with surrounding lines).
        if s.hasPrefix("<<<"), let endRange = s.range(of: ">>>") {
            s = String(s[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Backstop: the model occasionally echoes a stray `<<<` or `>>>` mid- or
        // end-of-output that the prefix strip above missed. These are never
        // legitimate transcript content, so remove them unconditionally and
        // tidy up any whitespace they leave behind.
        s = s.replacingOccurrences(of: "<<<", with: "")
        s = s.replacingOccurrences(of: ">>>", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

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
