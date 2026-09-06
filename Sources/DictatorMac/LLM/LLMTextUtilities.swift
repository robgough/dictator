import Foundation

/// Shared post-processing for LLM output. Both `MLXLLMService` and
/// `AppleFoundationLLMService` produce text that gets fed through the same
/// `<<<` / `>>>` wrapping protocol and the same `MODE: REPLACE/DRAFT` assistant
/// marker convention — so the cleaning and parsing rules are engine-agnostic
/// and live here rather than on either concrete service.
enum LLMTextUtilities {
    /// Strips wrapping artifacts the model occasionally emits — echoed
    /// `<<<...>>>` blocks, `Output:` labels, markdown code fences, surrounding
    /// quotes. Idempotent and safe to call on already-clean text.
    static func clean(_ raw: String) -> String {
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

    /// Pulls the `MODE: REPLACE`/`MODE: DRAFT` first-line marker the assistant
    /// prompt asks the model to emit and returns the body. Falls back to `.draft`
    /// (the safer default — clipboard-only, non-destructive) if the marker is
    /// missing or unrecognised.
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
                let split = extractRemember(from: stripAssistantPreamble(body))
                return AssistantResult(mode: mode, text: split.text, remember: split.remember)
            }
        }
        let split = extractRemember(from: stripAssistantPreamble(cleaned))
        return AssistantResult(mode: .draft, text: split.text, remember: split.remember)
    }

    /// Longest fact we'll accept off a `REMEMBER:` line. Beyond this the model
    /// isn't recording a preference, it's summarising the task — which is
    /// exactly what the prompt tells it not to do — so the line is dropped.
    static let maxRememberLength = 240

    /// Pulls a trailing `REMEMBER: <fact>` line off the assistant's output.
    ///
    /// The line is always stripped from the deliverable when it's recognised —
    /// it's protocol, never content, and pasting it into the user's document
    /// would be worse than losing the memory. Over-long lines are still
    /// stripped but the fact is discarded.
    ///
    /// Only fires when there's content left afterwards: an output that is
    /// *nothing but* a REMEMBER line is a malformed turn, and returning an
    /// empty deliverable turns it into a confusing "assistant returned no
    /// output" rather than something the user can see and react to.
    static func extractRemember(from text: String) -> (text: String, remember: String?) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let idx = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return (text, nil) }

        // Tolerate the markdown decoration small models sprinkle on labels.
        let line = lines[idx].trimmingCharacters(in: .whitespaces)
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•#> \t"))
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard bare.uppercased().hasPrefix("REMEMBER:") else { return (text, nil) }

        lines.removeSubrange(idx...)
        let remaining = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return (text, nil) }

        let fact = String(bare.dropFirst("REMEMBER:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, fact.count <= maxRememberLength else { return (remaining, nil) }
        return (remaining, fact)
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

    /// Wraps a piece of dictation in the standard `<<<` / `>>>` block so the model
    /// treats it as data rather than an instruction directed at it. Used by every
    /// engine in front of the formatter/grammar/structure passes.
    static func wrapAsData(_ text: String) -> String {
        "<<<\n\(text)\n>>>"
    }

    /// System prompt used by every engine's `summariseConversation` call. Engine-
    /// agnostic — the conversation-compaction shape is identical whether we're
    /// driving MLX or Apple Foundation.
    static let summariserSystemPrompt = """
    You are compacting an Assistant Mode conversation so the model can keep \
    following along after older turns have been trimmed. Write a single tight \
    summary (under 200 words). Preserve the user's intent, any names, decisions, \
    drafted text, and outstanding asks. Drop pleasantries and meta. Do NOT add \
    commentary, framing, headers, or preambles — return only the summary text.
    """

    /// Renders one Assistant Mode turn into the SELECTION + INSTRUCTION block shape
    /// the assistant prompt's few-shot examples train on.
    static func renderAssistantUserMessage(selection: String?, instruction: String) -> String {
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
        return """
        \(selectionBlock)

        INSTRUCTION:
        <<<
        \(instruction)
        >>>
        """
    }
}
