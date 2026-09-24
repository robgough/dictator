import Foundation

/// Dictator Meetings' meetings, read from disk for the chat assistant.
///
/// Meetings is a separate app, so none of its model types are compiled in
/// here. It writes every meeting as a folder in the same synced folder
/// Dictator uses — `Meetings/<uuid>/meta.json` and `transcript.json` — and
/// this reads just the fields the assistant needs out of those, tolerating
/// anything else. Foundation only, like `JournalArchive`, so it can be run
/// against a real archive outside the app.
struct MeetingArchive {
    /// Folders that may hold meetings: the synced folder's, then the per-Mac
    /// one Meetings falls back to without a synced folder.
    let roots: [URL]

    struct Meeting {
        let id: UUID
        let title: String
        let createdAt: Date
        let durationSeconds: Double
        /// Everyone but the user.
        let people: [String]
        let kind: String?
        /// The final notes, else the rough notes written during the call.
        let notes: String?
        let notesAreFinal: Bool
        let folder: URL
        /// speakerId → display name, for reading the transcript.
        let speakerNames: [String: String]

        var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    }

    // MARK: - Reading the archive

    func meetings() -> [Meeting] {
        var seen = Set<UUID>()
        var found: [Meeting] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for root in roots {
            guard let folders = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue }
            for folder in folders {
                let metaURL = folder.appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? decoder.decode(Meta.self, from: data),
                      !seen.contains(meta.id)
                else { continue }
                seen.insert(meta.id)
                let speakers = meta.speakers ?? []
                let final = meta.notes?.isFinal == true
                found.append(Meeting(
                    id: meta.id,
                    title: meta.title,
                    createdAt: meta.createdAt,
                    durationSeconds: meta.durationSeconds ?? 0,
                    people: speakers.filter { $0.isMe != true }.map(\.displayName),
                    kind: (meta.notes?.meetingType ?? meta.meetingType).flatMap { $0 == "auto" ? nil : $0 },
                    notes: final ? meta.notes?.markdown : (meta.rawNotes?.markdown ?? meta.notes?.markdown),
                    notesAreFinal: final,
                    folder: folder,
                    speakerNames: Dictionary(speakers.map { ($0.id, $0.isMe == true ? "\($0.displayName) (the user)" : $0.displayName) },
                                             uniquingKeysWith: { a, _ in a })))
            }
        }
        return found.sorted { $0.createdAt > $1.createdAt }
    }

    /// The transcript as "[mm:ss] Name: text" lines.
    func transcriptLines(for meeting: Meeting) -> [(seconds: Double, line: String)] {
        let url = meeting.folder.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { return [] }
        return transcript.segments.map { seg in
            let name = meeting.speakerNames[seg.speakerId] ?? seg.speakerId
            return (seg.start, "[\(Self.clock(seg.start))] \(name): \(seg.text)")
        }
    }

    // MARK: - Tool answers

    /// `search_meetings`. No query lists recent meetings; a query ranks them
    /// by title, people, notes and transcript, and quotes where it matched.
    func search(query: String, person: String?, daysBack: Int?, limit: Int = 8) -> String {
        var all = meetings()
        guard !all.isEmpty else { return "There are no meetings yet. Meetings are recorded with Dictator Meetings." }
        var scope = ""
        if let daysBack, daysBack > 0 {
            let cutoff = Calendar.current.startOfDay(
                for: Calendar.current.date(byAdding: .day, value: -(daysBack - 1), to: Date()) ?? Date())
            all = all.filter { $0.createdAt >= cutoff }
            scope = daysBack == 1 ? " from today" : " from the last \(daysBack) days"
        }
        if let person, !person.isEmpty {
            let p = person.lowercased()
            all = all.filter { $0.people.contains { $0.lowercased().contains(p) } }
            scope += " with \(person)"
        }
        guard !all.isEmpty else { return "No meetings\(scope)." }

        let terms = ChatSearch.terms(in: query)
        if terms.isEmpty {
            let shown = all.prefix(limit)
            return "The \(shown.count) most recent meetings\(scope), newest first:\n\n"
                + shown.map { describe($0, match: nil) }.joined(separator: "\n\n")
                + "\n\nUse read_meeting with an id to read a meeting's notes or transcript."
        }

        var scored: [(meeting: Meeting, score: Int, match: String?)] = []
        for meeting in all {
            let head = [meeting.title, meeting.people.joined(separator: " "), meeting.kind ?? "", meeting.notes ?? ""]
                .joined(separator: "\n")
            var score = ChatSearch.score(head, terms: terms)
            var match: String?
            if let line = firstLine(in: meeting.notes ?? "", matching: terms) {
                match = "In the notes: \(line)"
            }
            if score < terms.count {
                let lines = transcriptLines(for: meeting)
                let transcriptScore = ChatSearch.score(lines.map(\.line).joined(separator: "\n"), terms: terms)
                if transcriptScore > score {
                    score = transcriptScore
                    if let hit = lines.max(by: { ChatSearch.score($0.line, terms: terms) < ChatSearch.score($1.line, terms: terms) }) {
                        match = "In the transcript: \(Self.clip(hit.line, 240))"
                    }
                }
            }
            if score > 0 { scored.append((meeting, score, match)) }
        }
        guard !scored.isEmpty else { return "No meetings\(scope) mention \"\(query)\"." }
        let best = scored.map(\.score).max() ?? 0
        let full = scored.filter { $0.score == terms.count }
        let chosen = (full.isEmpty ? scored.filter { $0.score == best } : full).prefix(limit)
        return "\(chosen.count) \(chosen.count == 1 ? "meeting" : "meetings")\(scope) matched \"\(query)\", newest first:\n\n"
            + chosen.map { describe($0.meeting, match: $0.match) }.joined(separator: "\n\n")
            + "\n\nUse read_meeting with an id to read the full notes or transcript."
    }

    /// `read_meeting`: the notes, the transcript (in pages), or both.
    func read(id: String, part: String, fromMinute: Int?) -> String {
        let key = id.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return "No meeting id was given. Find one with search_meetings." }
        let all = meetings()
        guard let meeting = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(key) })
                ?? all.first(where: { $0.title.lowercased() == key })
        else { return "No meeting has the id \"\(id)\". Find one with search_meetings." }

        var out = [describe(meeting, match: nil)]
        let wantsNotes = part != "transcript"
        let wantsTranscript = part == "transcript" || part == "all"
        if wantsNotes {
            if let notes = meeting.notes, !notes.isEmpty {
                out.append(meeting.notesAreFinal
                    ? "NOTES:\n\(notes)"
                    : "ROUGH NOTES (written live during the call; speakers are only \"Me\" and \"Them\", and the final notes haven't been written):\n\(notes)")
            } else {
                out.append("This meeting has no notes yet. Read its transcript instead.")
            }
        }
        if wantsTranscript {
            out.append(transcriptPage(meeting, fromMinute: fromMinute))
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: - Private

    private static let transcriptPageCharacters = 12_000

    private func transcriptPage(_ meeting: Meeting, fromMinute: Int?) -> String {
        let lines = transcriptLines(for: meeting)
        guard !lines.isEmpty else { return "No transcript is available for this meeting." }
        let start = Double((fromMinute ?? 0) * 60)
        var page: [String] = []
        var size = 0
        var nextMinute: Int?
        for entry in lines where entry.seconds >= start {
            if size + entry.line.count > Self.transcriptPageCharacters, !page.isEmpty {
                nextMinute = Int(entry.seconds / 60)
                break
            }
            page.append(entry.line)
            size += entry.line.count + 1
        }
        guard !page.isEmpty else { return "The transcript ends before minute \(fromMinute ?? 0)." }
        var text = "TRANSCRIPT\(fromMinute.map { " from minute \($0)" } ?? ""):\n" + page.joined(separator: "\n")
        if let nextMinute {
            text += "\n\n(The transcript continues. Call read_meeting with part \"transcript\" and from_minute \(nextMinute) for the next part.)"
        }
        return text
    }

    private func describe(_ m: Meeting, match: String?) -> String {
        var parts = ["[id: \(m.shortID)] \(m.title)"]
        parts.append(Self.dateFormatter.string(from: m.createdAt))
        if m.durationSeconds > 0 { parts.append("\(Int((m.durationSeconds / 60).rounded())) min") }
        var line = parts.joined(separator: " — ")
        if !m.people.isEmpty { line += "\nWith: \(m.people.joined(separator: ", "))" }
        if let kind = m.kind { line += "\nKind: \(kind)" }
        line += m.notesAreFinal ? "\nNotes: written" : (m.notes == nil ? "\nNotes: none yet" : "\nNotes: only rough live notes so far")
        if let summary = summary(of: m) { line += "\nSummary: \(summary)" }
        if let match { line += "\n\(match)" }
        return line
    }

    /// The first paragraph under a "Summary" heading, if the notes have one.
    private func summary(of m: Meeting) -> String? {
        guard m.notesAreFinal, let notes = m.notes else { return nil }
        var inSummary = false
        for raw in notes.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inSummary = line.lowercased().contains("summary")
            } else if inSummary, !line.isEmpty {
                return Self.clip(line, 300)
            }
        }
        return nil
    }

    private func firstLine(in text: String, matching terms: [String]) -> String? {
        text.components(separatedBy: "\n")
            .first { ChatSearch.score($0, terms: terms) > 0 && !$0.hasPrefix("#") }
            .map { Self.clip($0.trimmingCharacters(in: .whitespaces), 240) }
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    private static func clock(_ seconds: Double) -> String {
        let t = Int(seconds)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy, HH:mm"
        return f
    }()

    // Just the fields read here; everything else in meta.json is ignored.
    private struct Meta: Decodable {
        let id: UUID
        let title: String
        let createdAt: Date
        let durationSeconds: Double?
        let speakers: [Speaker]?
        let notes: Notes?
        let rawNotes: Notes?
        let meetingType: String?

        enum CodingKeys: String, CodingKey {
            case id, title, createdAt, durationSeconds, speakers, notes, rawNotes, meetingType
        }

        /// Only the id, title and date are required. Every other field is
        /// read with `try?`, so one that Meetings has since changed the shape
        /// of costs that field, not the whole meeting.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
            speakers = try? c.decodeIfPresent([Speaker].self, forKey: .speakers)
            notes = try? c.decodeIfPresent(Notes.self, forKey: .notes)
            rawNotes = try? c.decodeIfPresent(Notes.self, forKey: .rawNotes)
            meetingType = try? c.decodeIfPresent(String.self, forKey: .meetingType)
        }

        struct Speaker: Decodable {
            let id: String
            let displayName: String
            let isMe: Bool?
        }
        struct Notes: Decodable {
            let markdown: String
            let isFinal: Bool?
            let meetingType: String?

            enum CodingKeys: String, CodingKey { case markdown, isFinal, meetingType }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                markdown = try c.decode(String.self, forKey: .markdown)
                isFinal = try? c.decodeIfPresent(Bool.self, forKey: .isFinal)
                meetingType = try? c.decodeIfPresent(String.self, forKey: .meetingType)
            }
        }
    }

    private struct Transcript: Decodable {
        let segments: [Segment]
        struct Segment: Decodable {
            let start: Double
            let speakerId: String
            let text: String
        }
    }
}
