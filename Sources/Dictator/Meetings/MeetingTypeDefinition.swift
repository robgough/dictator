import Foundation

/// Full definition of a meeting type — built-in or user-created. The id is
/// what's persisted on meetings (`MeetingMeta.meetingType`); everything else
/// is presentation + prompt material resolved through `MeetingTypeRegistry`.
///
/// The `template` is the user-facing format both built-in and custom types
/// are written in: ALL-CAPS lines name the sections the notes should have,
/// the lines beneath each header are guidance for that section, and any text
/// before the first header is general guidance for the type. A template with
/// no headers at all is pure prose steering — the base prompt's standard
/// sections stand (that's how most built-ins behave).
struct MeetingTypeDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    /// One-line description. Doubles as the type's entry in the auto-detect
    /// classification prompt, so keep it terse and discriminative.
    var detail: String
    var template: String
    /// The keyword the auto-detect classification prompt asks the model to
    /// emit for this type. Set explicitly on built-ins (kept verbatim from
    /// the original hand-tuned detection prompt); nil on custom types, which
    /// derive one from their display name.
    var detectionKeyword: String?
    /// True for the types that ship with the app — read-only in the editor,
    /// duplicable as a starting point. Never persisted: anything decoded
    /// from settings is by definition a custom type.
    var isBuiltIn: Bool

    var meetingTypeID: MeetingTypeID { MeetingTypeID(id) }

    /// Keyword for the auto-detect prompt: the hand-tuned one for built-ins,
    /// a display-name slug for custom types ("Eng sync" → "eng-sync").
    var effectiveDetectionKeyword: String {
        detectionKeyword ?? Self.slug(from: displayName)
    }

    init(
        id: String,
        displayName: String,
        detail: String,
        template: String,
        detectionKeyword: String? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.template = template
        self.detectionKeyword = detectionKeyword
        self.isBuiltIn = isBuiltIn
    }

    /// Only custom types are ever encoded (into settings), so `isBuiltIn`
    /// and `detectionKeyword` stay out of the persisted shape entirely.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, detail, template
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        self.detectionKeyword = nil
        self.isBuiltIn = false
    }

    /// Lowercased, hyphen-joined alphanumerics: "Eng sync!" → "eng-sync".
    /// Used for custom-type ids and detection keywords.
    static func slug(from name: String) -> String {
        let parts = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return parts.joined(separator: "-")
    }

    /// A fresh id for a custom type named `name`, unique against `existing`
    /// (pass every id in the registry — built-in and custom). Falls back to
    /// "custom" when the name slugs to nothing, and suffixes -2, -3, … on
    /// collision so two types named "Sync" don't share an id.
    static func makeID(from name: String, existing: Set<String>) -> String {
        let base = slug(from: name).isEmpty ? "custom" : slug(from: name)
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// Turns a meeting-type template into the prompt addendum stitched under the
/// built-in notes prompt by `DictatorSettings.effectiveMeetingSummaryPrompt`.
/// Pure string work — no state, no actor.
enum MeetingTemplateCompiler {
    struct ParsedTemplate: Equatable {
        /// Free-form guidance before the first ALL-CAPS header. The whole
        /// template when there are no headers.
        var preamble: String
        /// (header as written, guidance lines beneath it) in template order.
        /// Guidance may be empty — a bare header still names a section.
        var sections: [Section]

        struct Section: Equatable {
            var header: String
            var guidance: String
        }
    }

    /// A line is a section header when, after trimming, it's non-empty,
    /// equals its own uppercased form, and contains at least one letter —
    /// so `ACTION ITEMS` and `Q3 REVIEW` qualify while bullets, numbers,
    /// and `---` rules don't. Lines starting with a markdown bullet or
    /// checkbox marker never count, even if fully uppercase.
    nonisolated static func isHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard trimmed == trimmed.uppercased() else { return false }
        guard trimmed.contains(where: { $0.isLetter }) else { return false }
        for marker in ["- ", "* ", "+ ", "> ", "#"] where trimmed.hasPrefix(marker) { return false }
        return true
    }

    nonisolated static func parse(_ template: String) -> ParsedTemplate {
        var preambleLines: [String] = []
        var sections: [ParsedTemplate.Section] = []
        for line in template.components(separatedBy: "\n") {
            if isHeaderLine(line) {
                sections.append(.init(header: line.trimmingCharacters(in: .whitespaces), guidance: ""))
            } else if var last = sections.popLast() {
                last.guidance += last.guidance.isEmpty ? line : "\n" + line
                sections.append(last)
            } else {
                preambleLines.append(line)
            }
        }
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ParsedTemplate(
            preamble: trim(preambleLines.joined(separator: "\n")),
            sections: sections.map { .init(header: $0.header, guidance: trim($0.guidance)) }
        )
    }

    /// `ACTION ITEMS` → `Action items`, matching the sentence-case headings
    /// the base prompt and the markdown renderer already use.
    nonisolated static func sectionTitle(from header: String) -> String {
        let lowered = header.lowercased()
        guard let first = lowered.first else { return lowered }
        return first.uppercased() + lowered.dropFirst()
    }

    /// The compiled prompt addendum for a type — the full `MEETING TYPE:`
    /// block appended under the built-in notes prompt. Empty when the type
    /// carries no steering at all (the "Other" choice).
    ///
    /// Headerless templates compile to plain prose under the type banner —
    /// byte-compatible with the retired enum's `promptAddendum` stitching, so
    /// the prose built-ins (1-on-1, stand-up, …) produce the exact prompt
    /// they always did. Section-bearing templates additionally emit a section
    /// contract that REPLACES the base prompt's standard list: the headers
    /// give membership and order, the guidance gives per-section emphasis,
    /// and the base prompt's formatting/grounding/attribution rules continue
    /// to apply unchanged.
    nonisolated static func compile(_ def: MeetingTypeDefinition) -> String {
        let parsed = parse(def.template)
        if parsed.preamble.isEmpty && parsed.sections.isEmpty { return "" }

        var out = "MEETING TYPE: \(def.displayName)\n"
        if !parsed.preamble.isEmpty {
            out += parsed.preamble
        }
        guard !parsed.sections.isEmpty else { return out }

        if !parsed.preamble.isEmpty { out += "\n\n" }
        out += """
        For this meeting type, structure the notes with EXACTLY these sections, in this order, each introduced by a `##` heading — this list replaces the standard section list above. Every other rule from the system prompt still applies: OMIT any section that has no content (heading and all), but always include `## Summary`.
        """
        for section in parsed.sections {
            out += "\n\n## \(sectionTitle(from: section.header))"
            if !section.guidance.isEmpty {
                out += "\n" + section.guidance
            }
        }
        return out
    }
}
