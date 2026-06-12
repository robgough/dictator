import SwiftUI

/// The live checklist: rows tick off as the watcher (or a click) marks them
/// covered, ad-hoc items get a dismiss control, and the add row captures
/// mid-meeting items — typed one at a time, pasted as a whole markdown list
/// (bullets stripped), or pulled in from a built-in set / saved profile via
/// the menu. Used in the live recording pane and inside the island's
/// expanded state — semantic colours only, so it reads correctly on both.
struct CoachChecklistPanel: View {
    @Environment(AppState.self) private var state
    let engine: MeetingCoachEngine
    var compact = false

    @State private var newItemText = ""
    @State private var showingSaveAsSet = false
    @State private var newSetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            ForEach(engine.checklist.filter { $0.status != .dismissed }) { entry in
                row(entry)
            }
            addRow
        }
        .alert("Save key points as a set", isPresented: $showingSaveAsSet) {
            TextField("Set name (e.g. Client type B)", text: $newSetName)
            Button("Save") { saveCurrentAsSet() }
            Button("Cancel", role: .cancel) { newSetName = "" }
        } message: {
            Text("Saved sets appear in the add menu for any future meeting.")
        }
    }

    private func row(_ entry: CoachChecklistEntry) -> some View {
        HStack(spacing: 7) {
            Button {
                engine.toggleDone(id: entry.id)
            } label: {
                Image(systemName: entry.isPending ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(entry.isPending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
                    .font(.system(size: compact ? 12 : 14))
            }
            .buttonStyle(.plain)

            Text(entry.text)
                .font(.system(size: compact ? 11 : 12))
                .strikethrough(!entry.isPending)
                .foregroundStyle(entry.isPending ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(2)

            if entry.source == .adhoc, entry.isPending {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Added mid-meeting — the coach will remind you until it's covered")
            }
            Spacer(minLength: 0)
            if entry.isPending {
                Button {
                    engine.dismissItem(id: entry.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Never mind — drop without counting as missed")
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.tertiary)
            // axis .vertical so a pasted multi-line markdown list arrives
            // intact; commit fires on return or on any pasted newline.
            TextField("Add something to cover — or paste a list…", text: $newItemText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: compact ? 11 : 12))
                .onSubmit(commitNewItems)
                .onChange(of: newItemText) { _, text in
                    if text.contains("\n") { commitNewItems() }
                }
            setsMenu
        }
    }

    /// Built-in sets (types that ship with coach checklists) + the user's
    /// saved profiles + save-current.
    private var setsMenu: some View {
        Menu {
            Section("Add from set") {
                ForEach(MeetingTypeRegistry.builtIns.filter { ($0.coach?.checklist.isEmpty == false) }) { def in
                    Button(def.displayName) {
                        engine.add(texts: def.coach?.checklist ?? [], source: .preset)
                    }
                }
                ForEach(state.settings.coachChecklistProfiles) { profile in
                    Button(profile.name) {
                        engine.add(texts: profile.items, source: .profile)
                    }
                }
            }
            if engine.checklist.contains(where: { $0.status != .dismissed }) {
                Divider()
                Button("Save current points as a set…") { showingSaveAsSet = true }
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add key points from a built-in set or a saved one")
    }

    /// Single typed line = an ad-hoc "don't let me forget" item (arms the
    /// reminder nudge). A pasted multi-line list = prep, not flags — those
    /// land as preset items so six pasted lines don't become six recurring
    /// reminders.
    private func commitNewItems() {
        let lines = newItemText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        newItemText = ""
        guard !lines.isEmpty else { return }
        engine.add(texts: lines, source: lines.count > 1 ? .preset : .adhoc)
    }

    private func saveCurrentAsSet() {
        let name = newSetName.trimmingCharacters(in: .whitespaces)
        newSetName = ""
        guard !name.isEmpty else { return }
        let items = engine.checklist
            .filter { $0.status != .dismissed }
            .map(\.text)
        guard !items.isEmpty else { return }
        let existing = Set(state.settings.coachChecklistProfiles.map(\.id))
        let id = MeetingTypeDefinition.makeID(from: name, existing: existing)
        state.settings.coachChecklistProfiles.append(
            CoachChecklistProfile(id: id, name: name, items: items)
        )
        state.save()
    }
}
