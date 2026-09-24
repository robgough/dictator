import SwiftUI

/// What the sidebar has selected: the Today screen, or one of the lists that
/// fill the meeting column beside the meeting itself — the way Mail's
/// mailboxes and Notes' folders do.
enum LibraryScope: Hashable {
    case today
    case all
    case needsNotes
    case kind(MeetingTypeID)
    case person(String)
}

/// The rules the library's lists and badges share, so "needs notes" means
/// the same thing in the sidebar count, the list badge and on Today.
enum Library {

    static func hasFinalNotes(_ meta: MeetingMeta) -> Bool {
        meta.notes?.isFinal == true || meta.summary != nil
    }

    /// A finished recording whose notes haven't been written. Anything with
    /// no duration is still being captured or imported.
    static func needsNotes(_ meta: MeetingMeta) -> Bool {
        !hasFinalNotes(meta) && meta.durationSeconds > 0
    }

    /// The kind a meeting is filed under: the type its notes were written
    /// as (which may have been detected), else the one the user picked.
    /// Auto with nothing written yet isn't a kind.
    static func kind(of meta: MeetingMeta) -> MeetingTypeID? {
        if hasFinalNotes(meta), let written = meta.notes?.meetingType, written != .auto { return written }
        return meta.meetingType == .auto ? nil : meta.meetingType
    }

    static func filter(_ metas: [MeetingMeta], by scope: LibraryScope) -> [MeetingMeta] {
        switch scope {
        case .today, .all:
            return metas
        case .needsNotes:
            return metas.filter(needsNotes)
        case .kind(let id):
            return metas.filter { kind(of: $0) == id }
        case .person(let personID):
            return metas.filter { $0.speakers.contains { $0.personID == personID } }
        }
    }

    @MainActor
    static func title(for scope: LibraryScope, settings: MeetingsSettings) -> String {
        switch scope {
        case .today: return "Today"
        case .all: return "All meetings"
        case .needsNotes: return "Needs notes"
        case .kind(let id): return MeetingTypeRegistry.displayName(for: id, settings: settings)
        case .person(let id): return personName(id: id, in: MeetingsStore.shared.visibleMetas)
        }
    }

    /// A person's name: the people store's (through the demo overlay, so a
    /// recording never shows a real colleague), else the name the most
    /// recent meeting they were in used for them.
    @MainActor
    static func personName(id: String, in metas: [MeetingMeta]) -> String {
        let people = MeetingsDemoMode.shared.people(real: PeopleStore.shared.people)
        if let person = people.first(where: { $0.id == id }) { return person.name }
        for meta in metas {
            if let speaker = meta.speakers.first(where: { $0.personID == id }) { return speaker.displayName }
        }
        return "Unknown"
    }
}

/// The sidebar: Today, the smart lists, then the kinds and people that
/// actually appear in this library. Kinds and people with no meetings are
/// left out — an empty folder is only a place to be disappointed.
struct LibrarySidebar: View {
    @Environment(MeetingsAppState.self) private var state
    @Binding var scope: LibraryScope?
    let metas: [MeetingMeta]

    var body: some View {
        List(selection: $scope) {
            Section {
                Label("Today", systemImage: "sun.max")
                    .tag(LibraryScope.today)
                row("All meetings", systemImage: "tray.full", count: metas.count, scope: .all)
                row("Needs notes", systemImage: "wand.and.stars",
                    count: metas.filter(Library.needsNotes).count, scope: .needsNotes, highlight: true)
            }
            if !kinds.isEmpty {
                Section("Kinds") {
                    ForEach(kinds, id: \.id) { entry in
                        row(entry.name, systemImage: "folder", count: entry.count, scope: .kind(entry.id))
                    }
                }
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people, id: \.id) { entry in
                        row(entry.name, systemImage: "person.crop.circle", count: entry.count, scope: .person(entry.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, systemImage: String, count: Int, scope: LibraryScope, highlight: Bool = false) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(highlight ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.secondary))
                        .fontWeight(highlight ? .semibold : .regular)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .tag(scope)
    }

    private var kinds: [(id: MeetingTypeID, name: String, count: Int)] {
        var counts: [MeetingTypeID: Int] = [:]
        for meta in metas {
            if let kind = Library.kind(of: meta) { counts[kind, default: 0] += 1 }
        }
        return counts
            .map { (id: $0.key, name: MeetingTypeRegistry.displayName(for: $0.key, settings: state.settings), count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// People who appear in at least one meeting, most frequent first. The
    /// user themself is left out: every meeting has them in it.
    private var people: [(id: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meta in metas {
            for id in Set(meta.speakers.filter { !$0.isMe }.compactMap(\.personID)) {
                counts[id, default: 0] += 1
            }
        }
        return counts.map { id, count in
            (id: id, name: Library.personName(id: id, in: metas), count: count)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        .prefix(12)
        .map { $0 }
    }
}
