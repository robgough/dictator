import Foundation

/// Turns whatever a model sent for `update_plan` into a list of steps.
///
/// Every model in the catalogue gets this argument wrong, in a different way.
/// Measured in `scratch/plan-follow-check` across all five, the schema asks for
/// an array of `{text, done}` objects and what actually arrives is:
///
/// - `"[{\"text\": \"Sort movers\", \"done\": false}, …]"` — the right shape,
///   JSON-encoded into a string (Qwen 3.5 4B, 9B)
/// - `"[\n  \"Find a photographer\", …]"` — an array of bare strings (E4B)
/// - `"[<|\"|>Search for three competitors…"` — Gemma's quote tokens leaking
///   into the JSON (Gemma 4 12B)
/// - `"[{done:false"` with the rest in sibling keys — truncated and split
/// - `["text": "Outline broadband cancellation"]` — a single step, no `steps`
///   key at all (Gemma 4 12B)
///
/// Refusing these would mean the feature never works for anyone, and "send it
/// again but properly" costs a round these models don't have to spare. So this
/// accepts all of them and normalises. It is deliberately forgiving in one
/// direction only: it will take a malformed list apart, but it never invents a
/// step that has no text.
enum PlanStepParsing {
    struct Parsed: Equatable {
        var text: String
        var done: Bool
    }

    /// Longest a step may be. A model asked for a plan will otherwise write the
    /// paragraph it was going to write anyway, and this rides in every prompt.
    static let maximumStepLength = 120
    /// Most steps kept. Past this it stops being a plan and starts being an
    /// outline of the answer.
    static let maximumSteps = 8

    /// `value` is the `steps` argument; `fallbackText` is a stray `text`
    /// argument, used only when there is no usable `steps`.
    static func steps(from value: Any?, fallbackText: String?) -> [Parsed] {
        var found = parse(value)
        if found.isEmpty, let fallbackText, !fallbackText.isEmpty {
            found = [Parsed(text: fallbackText, done: false)]
        }
        return
            found
            .map {
                Parsed(
                    text: String(clean($0.text).prefix(maximumStepLength)), done: $0.done)
            }
            .filter { !$0.text.isEmpty }
            .reduce(into: [Parsed]()) { out, step in
                // Models repeat themselves when they restate a plan; a list
                // with the same step twice reads as a mistake to the user.
                guard !out.contains(where: { $0.text.caseInsensitiveCompare(step.text) == .orderedSame })
                else { return }
                out.append(step)
            }
            .prefix(maximumSteps)
            .map { $0 }
    }

    private static func parse(_ value: Any?) -> [Parsed] {
        switch value {
        case let array as [Any]:
            return array.flatMap { element -> [Parsed] in
                if let text = element as? String { return [Parsed(text: text, done: false)] }
                if let object = element as? [String: Any] { return [fromObject(object)] }
                return []
            }
        case let string as String:
            return fromString(string)
        case let object as [String: Any]:
            return [fromObject(object)]
        default:
            return []
        }
    }

    private static func fromObject(_ object: [String: Any]) -> Parsed {
        let text = (object["text"] as? String)
            ?? (object["step"] as? String)
            ?? (object["title"] as? String)
            ?? ""
        let done = (object["done"] as? Bool)
            ?? (object["done"] as? String).map { $0.lowercased() == "true" }
            ?? (object["completed"] as? Bool)
            ?? false
        return Parsed(text: text, done: done)
    }

    /// A string that was meant to be an array. Tries JSON first, then falls
    /// back to splitting, because a truncated blob still contains the steps.
    private static func fromString(_ raw: String) -> [Parsed] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           !(decoded is String) {
            let parsed = parse(decoded)
            if !parsed.isEmpty { return parsed }
        }

        // Not valid JSON — usually truncated, or carrying a model's own quote
        // tokens. Pull out anything that looks like a step and keep going.
        if trimmed.contains("\"text\"") || trimmed.contains("text:") {
            let pattern = #""?text"?\s*:\s*"?([^"\n,}]+)"?"#
            let matches = trimmed.matches(of: try! Regex(pattern))
            let steps = matches.compactMap { match -> Parsed? in
                guard match.count > 1, let range = match[1].range else { return nil }
                return Parsed(text: String(trimmed[range]), done: false)
            }
            if !steps.isEmpty { return steps }
        }

        // Last resort: one step per line, or per bracketed chunk.
        let lines = trimmed
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { String($0) }
        let steps = lines.map { Parsed(text: $0, done: false) }
            .filter { !clean($0.text).isEmpty }
        return steps.count > 1 || !lines.isEmpty ? steps : []
    }

    /// Strips the JSON punctuation, quote tokens and list markers that come
    /// along when a model hand-writes its arguments.
    private static func clean(_ text: String) -> String {
        var out = text
        // Gemma emits its own quote tokens inside argument strings.
        for token in ["<|\"|>", "<|", "|>"] {
            out = out.replacingOccurrences(of: token, with: "")
        }
        out = out.replacingOccurrences(
            of: #"^[\s\[\]{}"'*\-•\d.)]+"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"["'\[\]{}]+$"#, with: "", options: .regularExpression)
        // A fragment that is only a flag, e.g. `done:false` split off its step.
        if out.range(of: #"^(done|completed)\s*[:=]"#, options: .regularExpression) != nil {
            return ""
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
