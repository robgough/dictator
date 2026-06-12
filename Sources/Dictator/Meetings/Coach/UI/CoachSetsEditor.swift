import SwiftUI

/// Manage the saved key-point sets (`CoachChecklistProfile`): rename, edit
/// items (one per line — pasted markdown bullets are stripped on save),
/// create, delete. Reached from Settings → Meetings and from the checklist
/// panel's set menu. Edits commit live to settings.
struct CoachSetsEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var name = ""
    @State private var itemsText = ""
    @State private var nudgeQuestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Key point sets")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(state.settings.coachChecklistProfiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .listStyle(.bordered)
                    HStack(spacing: 0) {
                        Button { addSet() } label: { Image(systemName: "plus") }
                            .frame(width: 24, height: 20)
                        Divider().frame(height: 14)
                        Button { deleteSelected() } label: { Image(systemName: "minus") }
                            .frame(width: 24, height: 20)
                            .disabled(selectedID == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }
                .frame(width: 160)

                if selectedID != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Set name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $itemsText)
                            .font(.system(size: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                        Text("One key point per line. Pasted markdown bullets are cleaned up automatically.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Toggle("Nudge me to ask questions when this set is in play", isOn: $nudgeQuestions)
                            .font(.caption)
                            .help("Discovery-style meetings: the coach prompts you after a long stretch without a question from you")
                    }
                } else {
                    VStack {
                        Spacer()
                        Text(state.settings.coachChecklistProfiles.isEmpty
                             ? "No sets yet — add one, or save a meeting's key points as a set from the checklist menu."
                             : "Select a set to edit it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
            }
            .frame(height: 240)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: selectedID) { _, _ in loadSelection() }
        .onChange(of: name) { _, _ in commit() }
        .onChange(of: itemsText) { _, _ in commit() }
        .onChange(of: nudgeQuestions) { _, _ in commit() }
        .onAppear {
            selectedID = state.settings.coachChecklistProfiles.first?.id
            loadSelection()
        }
    }

    private func loadSelection() {
        guard let profile = state.settings.coachChecklistProfiles.first(where: { $0.id == selectedID }) else {
            name = ""
            itemsText = ""
            nudgeQuestions = false
            return
        }
        name = profile.name
        itemsText = profile.items.joined(separator: "\n")
        nudgeQuestions = profile.armedNudges?.contains(CoachNudge.Kind.askQuestion.rawValue) == true
    }

    /// Live-commit the fields back to the selected profile. Item lines are
    /// cleaned of markdown furniture on the way in; blanks are kept while
    /// editing (dropping them live would eat the line you're typing) and
    /// filtered when the items are next used.
    private func commit() {
        guard let idx = state.settings.coachChecklistProfiles.firstIndex(where: { $0.id == selectedID }) else { return }
        var profile = state.settings.coachChecklistProfiles[idx]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let items = itemsText
            .components(separatedBy: .newlines)
            .map { MeetingCoachEngine.cleanItemText($0) }
        let cleanedItems = items.filter { !$0.isEmpty }
        let armed: [String]? = nudgeQuestions ? [CoachNudge.Kind.askQuestion.rawValue] : nil
        guard profile.name != trimmedName || profile.items != cleanedItems || profile.armedNudges != armed else { return }
        if !trimmedName.isEmpty { profile.name = trimmedName }
        profile.items = cleanedItems
        profile.armedNudges = armed
        state.settings.coachChecklistProfiles[idx] = profile
        state.save()
    }

    private func addSet() {
        let existing = Set(state.settings.coachChecklistProfiles.map(\.id))
        let id = MeetingTypeDefinition.makeID(from: "New set", existing: existing)
        state.settings.coachChecklistProfiles.append(
            CoachChecklistProfile(id: id, name: "New set", items: [])
        )
        state.save()
        selectedID = id
    }

    private func deleteSelected() {
        guard let selectedID else { return }
        state.settings.coachChecklistProfiles.removeAll { $0.id == selectedID }
        state.save()
        self.selectedID = state.settings.coachChecklistProfiles.first?.id
        loadSelection()
    }
}
