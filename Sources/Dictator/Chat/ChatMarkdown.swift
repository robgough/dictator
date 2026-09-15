import Foundation

/// Splits an assistant reply into prose and fenced code blocks.
///
/// Needed because `AttributedString(markdown:)` handles *inline* markdown only.
/// Fenced code survives as literal backticks, and — the visible symptom — the
/// newlines inside a code block are folded away, so a Ruby script the model
/// wrote line by line arrives as one long line. Markdown's own rule is that
/// single newlines inside a paragraph are not line breaks; a code block is
/// exactly where that rule must not apply.
enum ChatMarkdown {
    enum Block: Equatable {
        case prose(String)
        /// `language` is whatever followed the opening fence, lowercased.
        case code(language: String?, code: String)
    }

    /// Parses fenced blocks (``` or ~~~).
    ///
    /// Tolerant of a reply that is still arriving: an unclosed fence is
    /// returned as a code block with what has landed so far, so a script
    /// renders as a script while it streams rather than snapping from prose to
    /// code when the closing fence appears.
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var fence: String?
        var language: String?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose.removeAll()
            if !joined.isEmpty { blocks.append(.prose(joined)) }
        }
        func flushCode() {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
            code.removeAll()
            language = nil
            fence = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                // Only the matching marker closes it, so ``` inside a ~~~ block
                // is content.
                let marker = open.first ?? "`"
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == marker }) {
                    flushCode()
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                flushProse()
                fence = marker
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                language = info.isEmpty ? nil : info
                continue
            }
            prose.append(line)
        }

        if fence != nil {
            flushCode()   // still streaming, or the model forgot to close it
        } else {
            flushProse()
        }
        return blocks
    }
}

/// Minimal syntax highlighting.
///
/// Pure Foundation and deliberately shallow: it tokenises comments, strings,
/// numbers and a per-language keyword set, and nothing else. A real parser per
/// language would be a project of its own, and the point here is that a block
/// of code reads as code — structure at a glance — not that every identifier is
/// classified correctly. Returning ranges rather than coloured text keeps this
/// testable without SwiftUI.
enum CodeHighlighter {
    enum Kind: Equatable {
        case plain, keyword, string, comment, number
    }

    struct Token: Equatable {
        let range: Range<String.Index>
        let kind: Kind
    }

    /// Languages we know keywords for. Anything else still gets strings,
    /// comments and numbers, which is most of the visual benefit.
    private static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class",
                  "enum", "protocol", "extension", "import", "for", "in", "while", "switch",
                  "case", "default", "break", "continue", "throw", "throws", "try", "catch",
                  "do", "async", "await", "static", "private", "public", "internal", "self",
                  "init", "nil", "true", "false", "some", "any", "where", "as", "is"],
        "ruby": ["def", "end", "if", "elsif", "else", "unless", "while", "until", "for",
                 "in", "do", "then", "class", "module", "require", "require_relative",
                 "return", "yield", "begin", "rescue", "ensure", "raise", "attr_accessor",
                 "attr_reader", "attr_writer", "self", "nil", "true", "false", "puts", "new",
                 "each", "map", "lambda", "proc", "case", "when"],
        "python": ["def", "class", "if", "elif", "else", "for", "while", "in", "return",
                   "import", "from", "as", "try", "except", "finally", "raise", "with",
                   "lambda", "yield", "pass", "break", "continue", "None", "True", "False",
                   "and", "or", "not", "self", "async", "await", "print"],
        "javascript": ["function", "const", "let", "var", "if", "else", "for", "while",
                       "return", "class", "extends", "new", "this", "import", "export",
                       "from", "default", "async", "await", "try", "catch", "finally",
                       "throw", "typeof", "instanceof", "null", "undefined", "true", "false"],
        "bash": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                 "case", "esac", "function", "return", "export", "local", "echo", "cd",
                 "set", "source"],
        "json": ["true", "false", "null"],
    ]

    private static let aliases: [String: String] = [
        "rb": "ruby", "py": "python", "js": "javascript", "ts": "javascript",
        "typescript": "javascript", "jsx": "javascript", "tsx": "javascript",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
    ]

    /// Line-comment markers per language. `#` is wrong for JavaScript and right
    /// for nearly everything else people paste.
    private static func lineComment(for language: String?) -> [String] {
        switch language {
        case "swift", "javascript": return ["//"]
        case "ruby", "python", "bash", "yaml", "toml": return ["#"]
        case "sql": return ["--"]
        case "json": return []
        case nil: return ["//", "#"]
        default: return ["//", "#"]
        }
    }

    static func tokens(in code: String, language rawLanguage: String?) -> [Token] {
        let language = rawLanguage.map { aliases[$0] ?? $0 }
        let words = language.flatMap { keywords[$0] } ?? []
        let comments = lineComment(for: language)

        var tokens: [Token] = []
        var index = code.startIndex

        while index < code.endIndex {
            let character = code[index]

            // Comment to end of line.
            if let marker = comments.first(where: { code[index...].hasPrefix($0) }) {
                _ = marker
                let end = code[index...].firstIndex(of: "\n") ?? code.endIndex
                tokens.append(Token(range: index..<end, kind: .comment))
                index = end
                continue
            }
            // Block comment.
            if code[index...].hasPrefix("/*") {
                let searchFrom = code.index(index, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
                let close = code.range(of: "*/", range: searchFrom..<code.endIndex)
                let end = close?.upperBound ?? code.endIndex
                tokens.append(Token(range: index..<end, kind: .comment))
                index = end
                continue
            }
            // String literal, honouring backslash escapes.
            if character == "\"" || character == "'" || character == "`" {
                var cursor = code.index(after: index)
                var closed = false
                while cursor < code.endIndex {
                    if code[cursor] == "\\" {
                        cursor = code.index(cursor, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
                        continue
                    }
                    if code[cursor] == character {
                        cursor = code.index(after: cursor)
                        closed = true
                        break
                    }
                    // An unterminated quote shouldn't swallow the rest of the
                    // file — stop at the line end.
                    if code[cursor] == "\n" { break }
                    cursor = code.index(after: cursor)
                }
                _ = closed
                tokens.append(Token(range: index..<cursor, kind: .string))
                index = cursor
                continue
            }
            // Number.
            if character.isNumber {
                var cursor = index
                while cursor < code.endIndex,
                      code[cursor].isNumber || code[cursor] == "." || code[cursor] == "_" {
                    cursor = code.index(after: cursor)
                }
                tokens.append(Token(range: index..<cursor, kind: .number))
                index = cursor
                continue
            }
            // Word — keyword or not.
            if character.isLetter || character == "_" {
                var cursor = index
                while cursor < code.endIndex,
                      code[cursor].isLetter || code[cursor].isNumber || code[cursor] == "_" {
                    cursor = code.index(after: cursor)
                }
                let word = String(code[index..<cursor])
                if words.contains(word) {
                    tokens.append(Token(range: index..<cursor, kind: .keyword))
                }
                index = cursor
                continue
            }
            index = code.index(after: index)
        }
        return tokens
    }
}
