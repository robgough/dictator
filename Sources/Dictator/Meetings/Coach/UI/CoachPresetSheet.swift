import SwiftUI

/// Pre-record picker: choose the meeting type (one choice drives both the
/// notes template and the coach), layer client profiles on top, tweak the
/// merged checklist for this specific meeting, and go. Defaults to last
/// time's selections.
struct CoachPresetSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    /// (plan, coachDisabled) — plan nil + disabled when "without coach".
    let onStart: (CoachSessionPlan?, Bool) -> Void

    @State private var typeID: String = MeetingTypeID.auto.rawValue
    @State private var selectedProfileIDs: Set<String> = []
    /// One checklist item per line, freely editable for this meeting.
    @State private var checklistText = ""
    @State private var seeded = false
    @State private var newProfileName = ""
    @State private var newProfileItems = ""
    @State private var showNewProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record a meeting")
                .font(.title3.weight(.semibold))

            Picker("Meeting type", selection: $typeID) {
                ForEach(MeetingTypeRegistry.all(settings: state.settings)) { def in
                    Text(def.displayName).tag(def.id)
                }
            }
            .pickerStyle(.menu)

            if !state.settings.coachChecklistProfiles.isEmpty || showNewProfile {
                profilesSection
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Key points to cover")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $checklistText)
                    .font(.system(size: 12))
                    .frame(minHeight: 90, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                Text("One per line. The coach ticks them off live as they come up, and the scorecard shows what was missed. Empty = no checklist.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !showNewProfile {
                Button("Save these points as a profile…") { showNewProfile = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start without coach") {
                    persistDefaults()
                    dismiss()
                    onStart(nil, true)
                }
                Button("Start recording") {
                    persistDefaults()
                    dismiss()
                    onStart(buildPlan(), false)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: seedFromDefaults)
        .onChange(of: typeID) { _, _ in reseedChecklist() }
        .onChange(of: selectedProfileIDs) { _, _ in reseedChecklist() }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Client profiles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(state.settings.coachChecklistProfiles) { profile in
                Toggle(profile.name, isOn: Binding(
                    get: { selectedProfileIDs.contains(profile.id) },
                    set: { on in
                        if on { selectedProfileIDs.insert(profile.id) }
                        else { selectedProfileIDs.remove(profile.id) }
                    }
                ))
                .contextMenu {
                    Button("Delete profile", role: .destructive) {
                        state.settings.coachChecklistProfiles.removeAll { $0.id == profile.id }
                        selectedProfileIDs.remove(profile.id)
                        state.save()
                    }
                }
            }
            if showNewProfile {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Profile name (e.g. Client type B)", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $newProfileItems)
                        .font(.system(size: 12))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    HStack {
                        Button("Add profile") { addProfile() }
                            .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { showNewProfile = false }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Seeding & plan

    private func seedFromDefaults() {
        guard !seeded else { return }
        seeded = true
        if let last = state.settings.meetingLastPresetTypeID,
           MeetingTypeRegistry.all(settings: state.settings).contains(where: { $0.id == last }) {
            typeID = last
        } else {
            typeID = state.settings.defaultMeetingType.rawValue
        }
        selectedProfileIDs = Set(state.settings.meetingLastProfileIDs.filter { id in
            state.settings.coachChecklistProfiles.contains { $0.id == id }
        })
        // Seed the new-profile editor from nothing; checklist from selections.
        reseedChecklist()
    }

    /// Rebuild the merged checklist from the current type + profiles.
    /// Deliberately overwrites manual edits when the selection changes —
    /// edits last, selection changes reset.
    private func reseedChecklist() {
        let def = MeetingTypeRegistry.definition(for: MeetingTypeID(typeID), settings: state.settings)
        var lines = def.coach?.checklist ?? []
        for profile in state.settings.coachChecklistProfiles where selectedProfileIDs.contains(profile.id) {
            lines.append(contentsOf: profile.items)
        }
        checklistText = lines.joined(separator: "\n")
    }

    private func addProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        let items = newProfileItems
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !name.isEmpty else { return }
        let existing = Set(state.settings.coachChecklistProfiles.map(\.id))
        let id = MeetingTypeDefinition.makeID(from: name, existing: existing)
        state.settings.coachChecklistProfiles.append(
            CoachChecklistProfile(id: id, name: name, items: items)
        )
        selectedProfileIDs.insert(id)
        state.save()
        newProfileName = ""
        newProfileItems = ""
        showNewProfile = false
    }

    private func persistDefaults() {
        state.settings.meetingLastPresetTypeID = typeID
        state.settings.meetingLastProfileIDs = Array(selectedProfileIDs)
        state.save()
    }

    private func buildPlan() -> CoachSessionPlan {
        let def = MeetingTypeRegistry.definition(for: MeetingTypeID(typeID), settings: state.settings)
        let armed: Set<CoachNudge.Kind> = {
            guard let raw = def.coach?.armedNudges, !raw.isEmpty else { return CoachNudge.defaultArmed }
            return Set(raw.compactMap(CoachNudge.Kind.init(rawValue:)))
        }()

        // Attribute each (possibly hand-edited) line: exact match against a
        // selected profile's items → profile, everything else → preset.
        let profileItems: Set<String> = Set(
            state.settings.coachChecklistProfiles
                .filter { selectedProfileIDs.contains($0.id) }
                .flatMap(\.items)
                .map { $0.lowercased() }
        )
        let checklist: [(text: String, source: CoachChecklistEntry.Source)] = checklistText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                (line, profileItems.contains(line.lowercased()) ? .profile : .preset)
            }

        return CoachSessionPlan(
            typeID: typeID == MeetingTypeID.auto.rawValue ? nil : typeID,
            profileIDs: Array(selectedProfileIDs),
            checklist: checklist,
            armedNudges: armed
        )
    }
}
