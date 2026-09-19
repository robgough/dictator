import Foundation

/// Finds filenames a reply claims to have written, or is about to write.
///
/// Split out from the check that uses it so the fuzzy half can be tested on its
/// own: whether a file exists is a `stat`, but whether a sentence is a *claim*
/// is a judgement, and that is the half that gets this wrong in either
/// direction. Too eager and the assistant is nagged for discussing a filename;
/// too slack and "I'm creating research_roadmap_simple.html now." sails past,
/// which is the bug this exists for.
enum FileClaimDetector {
    /// Phrases that turn a filename into a promise.
    ///
    /// Present and future tense matter as much as past: the reported failure
    /// was an *announcement* ("I'm creating … now") that the model then never
    /// acted on, and a past-tense-only list misses every one of those.
    private static let claimPhrases = [
        "creating", "i've created", "i have created", "i created", "i'll create",
        "i will create", "let me create",
        "saving", "i've saved", "i have saved", "i saved", "i'll save", "i will save",
        "writing", "i've written", "i have written", "i wrote", "i'll write",
        "i will write", "let me write",
        "updating", "i've updated", "i have updated", "i updated", "i'll update",
        "generating", "i've generated", "i generated",
        "i've made", "i made", "i've put together", "here's the file",
        "the file is ready", "saved to", "written to",
    ]

    /// Filenames the text claims, in the order they appear.
    ///
    /// Returns every candidate rather than the first: a reply that names two
    /// files may have written one of them, and only the caller knows which.
    static func claimedFilenames(in text: String, allowedExtensions: Set<String>) -> [String] {
        let lowered = text.lowercased()
        guard claimPhrases.contains(where: { lowered.contains($0) }) else { return [] }
        guard !allowedExtensions.isEmpty else { return [] }

        let extensions = allowedExtensions
            .sorted()
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // A filename can carry spaces ("morning brief.html") but must not run
        // back into the sentence, so the run before the dot is bounded and the
        // extension must end on a word boundary.
        let pattern = #"[A-Za-z0-9][A-Za-z0-9._\-]{0,60}\.(?:"# + extensions + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var names: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matched = Range(match.range, in: text) else { continue }
            let name = String(text[matched]).trimmingCharacters(in: .whitespaces)
            // A bare extension, or a sentence that happened to end in one.
            guard name.count > 3, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}
