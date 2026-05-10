import Foundation

struct VocabularyEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var pattern: String
    var replacement: String
    var caseSensitive: Bool
    var wholeWord: Bool

    init(id: UUID = UUID(),
         pattern: String,
         replacement: String,
         caseSensitive: Bool = false,
         wholeWord: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

enum Vocabulary {
    /// Apply the user's dictionary to `text`, in declaration order. Each entry is a
    /// regex-escaped literal match (case-sensitive / whole-word per entry). Returns
    /// the original `text` unchanged when there's nothing to apply.
    static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var out = text
        for entry in entries {
            let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }

            var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
            if entry.wholeWord { regexPattern = "(?<!\\w)\(regexPattern)(?!\\w)" }

            var options: NSRegularExpression.Options = []
            if !entry.caseSensitive { options.insert(.caseInsensitive) }

            guard let regex = try? NSRegularExpression(pattern: regexPattern, options: options) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            let template = NSRegularExpression.escapedTemplate(for: entry.replacement)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }
}
