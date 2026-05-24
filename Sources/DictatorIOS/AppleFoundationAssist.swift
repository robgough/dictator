import Foundation
import FoundationModels

/// Apply a spoken instruction to existing transcript text using
/// Apple's on-device foundation model. Companion to
/// `AppleFoundationCleanup` — same availability story, different
/// task. Where cleanup removes filler, assist actively transforms:
/// "rewrite this politely", "remove all words ending in d",
/// "translate to French", "shorten this", etc.
///
/// Failure behaviour mirrors cleanup — throws on empty / refusal,
/// caller is expected to surface the error and keep the original text.
@MainActor
enum AppleFoundationAssist {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    enum AssistError: LocalizedError {
        case unavailable(String)
        case empty
        case refused

        var errorDescription: String? {
            switch self {
            case .unavailable(let r): r
            case .empty: "The assistant returned nothing — kept the original text."
            case .refused: "The assistant declined that one — kept the original text."
            }
        }
    }

    /// Apply `instruction` to `text`. Returns the model's transformed
    /// version. Caller is responsible for replacing the active
    /// transcript and persisting the prior version to history.
    static func transform(text: String, instruction: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason):
            throw AssistError.unavailable(String(describing: reason))
        }

        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        // Generous budget — assist can legitimately expand text
        // (e.g. "elaborate on this") so we don't cap as tightly as
        // cleanup. Still bounded at 2048 to avoid runaway generation.
        let approxInputTokens = max(32, (text.count + instruction.count) / 4)
        let maxTokens = min(2048, max(384, Int(Double(approxInputTokens) * 3.0)))
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.2,
            maximumResponseTokens: maxTokens
        )

        let prompt = """
        <TEXT>
        \(text)
        </TEXT>
        <INSTRUCTION>
        \(instruction)
        </INSTRUCTION>
        """

        let response = try await session.respond(to: prompt, options: options)
        var result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip echoed wrappers if the model included them.
        for wrapper in ["<TEXT>", "</TEXT>", "<INSTRUCTION>", "</INSTRUCTION>", "<OUTPUT>", "</OUTPUT>"] {
            result = result.replacingOccurrences(of: wrapper, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        NSLog("[DictatorIOS] Assist text=\(text.count)c inst=\(instruction.count)c out=\(result.count)c")

        guard !result.isEmpty else {
            throw AssistError.empty
        }

        // Refusal detection — same shapes the cleanup pass guards
        // against. Assist legitimately rewrites text, so we can't do
        // a length-based check; the refusal-prefix check is the only
        // automated guard.
        let head = result.lowercased().prefix(48)
        let refusalPrefixes = [
            "i cannot", "i can't", "i'm sorry", "i am sorry",
            "sorry, i", "sorry. i", "as an ai", "as a language model",
            "i won't", "i will not", "i'm unable", "i am unable",
            "i'm not able", "unfortunately, i",
        ]
        if refusalPrefixes.contains(where: { head.hasPrefix($0) }) {
            // Only flag if the original text didn't already look that
            // way — otherwise the model's just preserved a sentence
            // we're transforming.
            let textHead = text.lowercased().prefix(48)
            if !refusalPrefixes.contains(where: { textHead.hasPrefix($0) }) {
                throw AssistError.refused
            }
        }

        return result
    }

    /// System prompt for the transform task. Few-shot covering the
    /// main shapes of instruction: subtraction (remove words), style
    /// shift, punctuation/formatting, translation, expansion.
    private static let systemPrompt = """
    You apply transformations to text. The user supplies SOURCE text inside <TEXT> tags and an INSTRUCTION inside <INSTRUCTION> tags. Your job is to return the source text after applying the instruction — nothing else.

    Output rules:
    - Return ONLY the transformed text. No preamble, no quotes, no XML/HTML tags, no commentary.
    - If the instruction is ambiguous or impossible, return the source text unchanged.
    - Never apologise or refuse. If you can't help, return the source unchanged.
    - Preserve the speaker's tone and language. Don't censor profanity, swear words, or slang unless the instruction explicitly asks for that. No asterisks, no "[expletive]" placeholders, no softening — keep the words the user actually wrote.

    Examples:

    <TEXT>The quick brown fox jumps over the lazy dog.</TEXT>
    <INSTRUCTION>Remove every word that ends in "d".</INSTRUCTION>
    The quick brown fox jumps over the lazy.

    <TEXT>i went to the store and i bought some milk then i went home</TEXT>
    <INSTRUCTION>Add proper punctuation and capitalisation.</INSTRUCTION>
    I went to the store and I bought some milk. Then I went home.

    <TEXT>The meeting is at 3pm tomorrow.</TEXT>
    <INSTRUCTION>Translate to French.</INSTRUCTION>
    La réunion est à 15h demain.

    <TEXT>I love this product its amazing and works really well</TEXT>
    <INSTRUCTION>Make it sound more professional.</INSTRUCTION>
    I am highly impressed with this product; it is exceptional and performs reliably.

    <TEXT>I went to the shop. I bought milk. I came home.</TEXT>
    <INSTRUCTION>Combine into one sentence.</INSTRUCTION>
    I went to the shop, bought milk, and came home.

    <TEXT>Buy bread. Walk dog. Email Sarah.</TEXT>
    <INSTRUCTION>Format as a bullet list.</INSTRUCTION>
    - Buy bread
    - Walk dog
    - Email Sarah

    Output ONLY the transformed text. Nothing else.
    """
}
