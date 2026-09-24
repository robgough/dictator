import Foundation

/// Action items gathered across meetings, for the Today screen.
///
/// Read straight out of each meeting's final notes rather than stored
/// anywhere of their own: the notes are the source of truth, the user edits
/// them, and a second copy would drift the first time they did. An item is
/// any bullet or task under a heading that reads as actions ("Action items",
/// "Next steps", "To do") — the notes prompt writes `- [ ] **Owner** — text`,
/// older notes and hand edits write plain bullets, and both count.
struct ActionItem: Identifiable, Hashable {
    let meetingID: UUID
    let meetingTitle: String
    let meetingDate: Date
    /// The owner the notes named (`**Priya** — …`), if any.
    let owner: String?
    /// The item without its owner.
    let text: String
    let done: Bool
    /// The body exactly as it appears after the bullet (and task box), which
    /// is what `ActionItems.setDone` matches to find the line again.
    let lineBody: String

    var id: String { "\(meetingID.uuidString)|\(lineBody)" }
}

enum ActionItems {

    /// Headings whose bullets are actions. Kept in step with
    /// `MarkdownNotesView.sectionSymbol`, which picks the same headings out
    /// for their checklist icon.
    static func isActionHeading(_ heading: String) -> Bool {
        let h = heading.lowercased()
        return h.contains("action") || h.contains("next step") || h.contains("to do") || h.contains("todo")
    }

    /// Every action item in the final notes of `metas`. Drafts are skipped:
    /// live notes attribute only "Me" and "Them", so their owners would be
    /// wrong in exactly the way that matters for a list sorted by owner.
    static func collect(from metas: [MeetingMeta]) -> [ActionItem] {
        var items: [ActionItem] = []
        for meta in metas {
            guard let notes = meta.notes, notes.isFinal else { continue }
            var inActions = false
            for block in MarkdownBlock.parse(notes.markdown) {
                switch block.kind {
                case .heading:
                    inActions = isActionHeading(block.text)
                case .bullet, .task:
                    guard inActions, block.indent == 0 else { continue }
                    let lineBody = block.text
                    let (owner, rest) = MarkdownBlock.splitOwner(lineBody)
                    let cleaned = MarkdownBlock.extractTimestamps(rest).text
                    items.append(ActionItem(
                        meetingID: meta.id,
                        meetingTitle: meta.title,
                        meetingDate: meta.createdAt,
                        owner: owner,
                        text: cleaned,
                        done: block.kind == .task && block.checked,
                        lineBody: lineBody))
                default:
                    continue
                }
            }
        }
        return items
    }

    /// Whether an owner name means the person using the app. The notes name
    /// people as the transcript does, so "me" is whichever speaker is marked
    /// `isMe` in that meeting, or the name in Settings.
    static func isMine(_ item: ActionItem, meta: MeetingMeta?, userName: String) -> Bool {
        guard let owner = item.owner?.lowercased() else { return true }
        if ["me", "i", "you", "myself"].contains(owner) { return true }
        var names: [String] = []
        if let me = meta?.speakers.first(where: { $0.isMe }) { names.append(me.displayName) }
        if !userName.isEmpty { names.append(userName) }
        return names.contains { name in
            let n = name.lowercased()
            return n == owner || n.split(separator: " ").first.map(String.init) == owner
        }
    }

    /// Tick or untick an item in its meeting's notes, rewriting that one line
    /// as a task (`- [x] …`) and saving. A plain bullet becomes a task the
    /// first time it's ticked — which is also how it would render in the
    /// notes themselves from then on.
    @MainActor
    static func setDone(_ item: ActionItem, done: Bool) {
        let store = MeetingsStore.shared
        guard var meta = store.meta(id: item.meetingID), var notes = meta.notes else { return }
        var lines = notes.markdown.components(separatedBy: "\n")
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let body: String
            if let (_, taskBody) = MarkdownBlock.parseTask(trimmed) {
                body = taskBody
            } else if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            } else {
                continue
            }
            guard body == item.lineBody else { continue }
            let leading = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            lines[i] = "\(leading)- [\(done ? "x" : " ")] \(body)"
            break
        }
        notes.markdown = lines.joined(separator: "\n")
        meta.notes = notes
        try? MeetingStorage.writeMeta(meta)
        store.upsert(meta)
    }
}
