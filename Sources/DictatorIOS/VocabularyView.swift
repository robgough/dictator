import SwiftUI

/// Vocabulary editor — pushed from Settings. Extracted from
/// `SettingsView` so the main Settings list stays scannable; the
/// editor and per-row UI move with it because they're not used
/// anywhere else.
struct VocabularyView: View {
    @Bindable var store: VocabularyStore = .shared
    @State private var editingEntry: VocabularyEntry?
    @State private var showingNewSheet = false

    var body: some View {
        List {
            Section {
                if store.entries.isEmpty {
                    Text("No replacements yet. Tap + to add one — for example, fix how a name keeps coming out, or replace \"laughing emoji\" with 😂.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.entries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            VocabularyEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        store.entries.remove(atOffsets: offsets)
                    }
                    .onMove { from, to in
                        store.entries.move(fromOffsets: from, toOffset: to)
                    }
                }
            } footer: {
                Text("Rules run top to bottom after transcription, each on the result of the one before. New rules match anything that sounds like what you type.")
            }
        }
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.entries.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            VocabularyEntryEditor(entry: nil) { newEntry in
                // At the top, as on the Mac: rules run in order, and the
                // one just written is the one being fixed.
                store.entries.insert(newEntry, at: 0)
            }
        }
        .sheet(item: $editingEntry) { entry in
            VocabularyEntryEditor(entry: entry) { updated in
                if let index = store.entries.firstIndex(where: { $0.id == updated.id }) {
                    store.entries[index] = updated
                }
            }
        }
    }
}

// MARK: - Row

private struct VocabularyEntryRow: View {
    let entry: VocabularyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.pattern.isEmpty ? "—" : entry.pattern)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.replacement.isEmpty ? "—" : entry.replacement)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Badge(text: entry.matchMode.label, systemImage: entry.matchMode.symbol)
                if entry.matchMode.usesLiteralFlags, entry.caseSensitive {
                    Badge(text: "Aa", systemImage: "textformat")
                }
                if entry.matchMode == .literal, entry.wholeWord {
                    Badge(text: "Whole word", systemImage: "text.word.spacing")
                }
                if entry.validationProblem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("This rule won't do anything")
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color(.tertiarySystemBackground))
        )
        .foregroundStyle(.secondary)
    }
}

// MARK: - Editor

private struct VocabularyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let entry: VocabularyEntry?
    let onSave: (VocabularyEntry) -> Void

    @State private var pattern: String
    @State private var replacement: String
    @State private var caseSensitive: Bool
    @State private var wholeWord: Bool
    @State private var matchMode: VocabularyMatchMode

    init(entry: VocabularyEntry?, onSave: @escaping (VocabularyEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _pattern = State(initialValue: entry?.pattern ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
        _wholeWord = State(initialValue: entry?.wholeWord ?? true)
        _matchMode = State(initialValue: entry?.matchMode ?? .defaultForNewRule)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(matchMode == .regex ? "Pattern" : "Heard", text: $pattern,
                              prompt: Text(matchMode == .regex ? "e.g. \\bdictator\\b" : "e.g. laughing emoji"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(matchMode == .regex ? .body.monospaced() : .body)
                    TextField("Replacement", text: $replacement, prompt: Text("e.g. 😂"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let problem = draft.validationProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else if let note = draft.validationNote {
                        Label(note, systemImage: "info.circle")
                    }
                }

                Section {
                    Picker("Match", selection: $matchMode) {
                        ForEach(VocabularyMatchMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    // Case and word boundaries only mean something for exact
                    // text or a regex; sounds-like compares sounds word by
                    // word, so the switches would be lying about what they do.
                    if matchMode.usesLiteralFlags {
                        Toggle("Case sensitive", isOn: $caseSensitive)
                    }
                    if matchMode == .literal {
                        Toggle("Whole words only", isOn: $wholeWord)
                    }
                } footer: {
                    Text(matchMode.summary)
                }
            }
            .navigationTitle(entry == nil ? "New Replacement" : "Edit Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedPattern.isEmpty else { return }
                        var saved = draft
                        saved.pattern = trimmedPattern
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var draft: VocabularyEntry {
        VocabularyEntry(
            id: entry?.id ?? UUID(),
            pattern: pattern,
            replacement: replacement,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord,
            matchMode: matchMode
        )
    }
}

private extension VocabularyMatchMode {
    var symbol: String {
        switch self {
        case .literal: "equal"
        case .phonetic: "waveform"
        case .regex: "asterisk"
        }
    }
}
