import SwiftUI

/// What the meeting-type editor sheet was opened to do. `view` is the
/// read-only mode for built-ins (with a "Duplicate to edit" escape hatch);
/// `edit` mutates an existing custom type in place (id stays stable so
/// meetings referencing it keep resolving); `create` makes a new custom
/// type, optionally seeded from a duplicate source.
enum MeetingTypeEditorMode: Identifiable {
    case view(MeetingTypeDefinition)
    case edit(MeetingTypeDefinition)
    case create(seed: MeetingTypeDefinition?)

    var id: String {
        switch self {
        case .view(let def):   return "view-\(def.id)"
        case .edit(let def):   return "edit-\(def.id)"
        case .create(let seed): return "create-\(seed?.id ?? "blank")"
        }
    }
}

/// Sheet for viewing, editing, or creating a meeting-type definition. The
/// template area is the same ALL-CAPS section format the built-ins use —
/// the live "Sections" line under the editor shows what the compiler will
/// actually produce, so a header that didn't register is visible immediately.
struct MeetingTypeEditorSheet: View {
    @Environment(MeetingsAppState.self) private var state
    let mode: MeetingTypeEditorMode
    let onDuplicate: (MeetingTypeDefinition) -> Void

    @State private var name: String = ""
    @State private var detail: String = ""
    @State private var template: String = ""
    @Environment(\.dismiss) private var dismiss

    /// Scaffold for a from-scratch type — a worked example beats an empty
    /// box for a format the user hasn't written before.
    private static let blankTemplate = """
    SUMMARY
    2–3 sentences on what the meeting covered.

    DISCUSSION
    The main points discussed, with the specifics given.

    DECISIONS
    What was actually agreed. Omit if none.

    ACTION ITEMS
    Attribute each task to its owner.
    """

    private var isReadOnly: Bool {
        if case .view = mode { return true }
        return false
    }

    private var title: String {
        switch mode {
        case .view(let def): return def.displayName
        case .edit:          return "Edit note style"
        case .create:        return "New note style"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                if isReadOnly {
                    MeetingChip("Built-in", tone: .neutral, uppercased: true)
                }
                Spacer()
                if isReadOnly {
                    Button {
                        if case .view(let def) = mode {
                            dismiss()
                            onDuplicate(def)
                        }
                    } label: {
                        Label("Duplicate to edit", systemImage: "plus.square.on.square")
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { save(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            }
            .padding()
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.subheadline.weight(.medium))
                    TextField("Eng sync", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isReadOnly)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.subheadline.weight(.medium))
                    Text("One line on what this kind of meeting is. Auto-detect uses it to recognise the meeting from the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("A weekly engineering sync: updates, risks, and decisions", text: $detail)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isReadOnly)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes template")
                        .font(.subheadline.weight(.medium))
                    Text("ALL-CAPS lines become section headings, in the order you list them; the text under each header tells the model what belongs there. Text before the first header is general guidance. No ALL-CAPS headers at all? The standard sections apply and your text steers them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $template)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                        .frame(minHeight: 240, maxHeight: .infinity)
                        .disabled(isReadOnly)
                    sectionPreview
                }
            }
            .padding()
        }
        .frame(width: 640, height: 640)
        .onAppear(perform: load)
    }

    /// Live readout of what the compiler sees — the heading list a
    /// section-bearing template will produce, or a note that the template
    /// is guidance-only. Catches "my header didn't take" instantly.
    @ViewBuilder
    private var sectionPreview: some View {
        let parsed = MeetingTemplateCompiler.parse(template)
        if parsed.sections.isEmpty {
            Text("No sections defined — the notes keep the standard shape: a Summary, the discussion grouped into topic sections, then Decisions, Action items, and any notable quotes or items to verify.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            (Text("Sections: ").foregroundStyle(.secondary)
                + Text(parsed.sections.map { MeetingTemplateCompiler.sectionTitle(from: $0.header) }
                    .joined(separator: " · ")))
                .font(.caption)
        }
    }

    private func load() {
        switch mode {
        case .view(let def), .edit(let def):
            name = def.displayName
            detail = def.detail
            template = def.template
        case .create(let seed):
            if let seed {
                name = "\(seed.displayName) copy"
                detail = seed.detail
                template = seed.template
            } else {
                name = ""
                detail = ""
                template = Self.blankTemplate
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .view:
            return
        case .edit(let original):
            guard let idx = state.settings.customMeetingTypes.firstIndex(where: { $0.id == original.id }) else { return }
            state.settings.customMeetingTypes[idx].displayName = trimmedName
            state.settings.customMeetingTypes[idx].detail = detail.trimmingCharacters(in: .whitespaces)
            state.settings.customMeetingTypes[idx].template = template
        case .create:
            let existing = Set(MeetingTypeRegistry.all(settings: state.settings).map(\.id))
            let def = MeetingTypeDefinition(
                id: MeetingTypeDefinition.makeID(from: trimmedName, existing: existing),
                displayName: trimmedName,
                detail: detail.trimmingCharacters(in: .whitespaces),
                template: template
            )
            state.settings.customMeetingTypes.append(def)
        }
        state.save()
    }
}
