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
                    Text("No replacements yet. Tap + to add one — for example, replace \"laughing emoji\" with 😂, or your codename with the real spelling.")
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
                        for index in offsets {
                            store.entries.remove(at: index)
                        }
                    }
                }
            } footer: {
                Text("Applied after transcription, in order. Matches whole words by default (case-insensitive). Tap a row to change those options.")
            }
        }
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
                store.entries.append(newEntry)
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
                if entry.caseSensitive {
                    Badge(text: "Aa", systemImage: "textformat")
                }
                if entry.wholeWord {
                    Badge(text: "Whole word", systemImage: "text.word.spacing")
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

    init(entry: VocabularyEntry?, onSave: @escaping (VocabularyEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _pattern = State(initialValue: entry?.pattern ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
        _wholeWord = State(initialValue: entry?.wholeWord ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pattern", text: $pattern, prompt: Text("e.g. laughing emoji"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Replacement", text: $replacement, prompt: Text("e.g. 😂"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Match")
                } footer: {
                    Text("The pattern is matched literally — no regex needed.")
                }

                Section {
                    Toggle("Case sensitive", isOn: $caseSensitive)
                    Toggle("Whole words only", isOn: $wholeWord)
                } footer: {
                    Text("With Whole words off, partial matches inside other words count. With case sensitivity on, \"hello\" won't match \"Hello\".")
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
                        let saved = VocabularyEntry(
                            id: entry?.id ?? UUID(),
                            pattern: trimmedPattern,
                            replacement: replacement,
                            caseSensitive: caseSensitive,
                            wholeWord: wholeWord
                        )
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
