import SwiftUI
import AppKit

/// Sort options for the dictionary list. Held on the shell model (the
/// toolbar's sort menu drives it); the underlying `settings.vocabulary`
/// array is always stored in "as entered" order — sorting is purely a
/// display concern. Internal, not private: `SettingsShellModel` and the
/// toolbar fragment in SettingsShell.swift use it too.
enum VocabularySortOrder: String, CaseIterable, Identifiable {
    case alphabetical
    case asEntered

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .asEntered:    "As entered"
        }
    }
}

/// Open System Settings on the Keyboard pane. On macOS Sequoia the
/// Services checkbox list is buried behind a "Keyboard Shortcuts…"
/// sheet — no URL scheme jumps inside that sheet, and the legacy
/// `reveal anchor` AppleScript command was removed in Ventura. We tried
/// driving the click-through via Accessibility, but System Settings is
/// SwiftUI-internally so its AX titles sit on descendants of the
/// pressable element and the heuristic was unreliable. Better to just
/// land on the Keyboard pane and spell out the remaining two clicks
/// in the tooltip.
@MainActor
private func openServicesSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
}

struct DictionaryPane: View {
    @Environment(AppState.self) private var state
    /// VocabularyStore is observable, so referencing it here participates in
    /// Observation tracking — UI re-renders when entries change (whether the
    /// change came from the UI itself or from an external file edit / sync
    /// drop the vnode watcher picked up).
    @State private var store = VocabularyStore.shared

    /// Search text, sort order, and the add-entry action live in the window
    /// toolbar (SettingsShell); this pane reads them off the shared model.
    let shell: SettingsShellModel

    /// New rows go to the top of the visible list and get auto-focused, so
    /// the user can start typing immediately. The id picked here is the
    /// one to pulse-highlight + focus on next render.
    @FocusState private var focusedFieldID: VocabularyEntry.ID?

    @State private var tester = DictionaryTester.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            learnWordRows
            if let err = tester.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(err)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { tester.dismissError() }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
            list(vocabBinding)
        }
        // Focus request from the toolbar's Add button: apply, then
        // consume so the next Add re-fires.
        .onChange(of: shell.dictionaryFocusEntryID) { _, id in
            guard let id else { return }
            focusedFieldID = id
            shell.dictionaryFocusEntryID = nil
        }
    }

    /// The two "Learn Word" affordances, one line each: what the service does
    /// and how to switch it on. The step-by-step used to be a popover of
    /// bolded prose; it's a tooltip now.
    private var learnWordRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Add words from any app")
                    .help("Select text in any app, then right-click \u{2192} Services \u{2192} \u{201C}Learn Word in Dictator\u{2026}\u{201D}.")
                Spacer()
                Text(countLabel(total: store.entries.count,
                                shown: filteredEntries(from: store.entries).count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Turn the service on")
                    .help("In System Settings, click \u{201C}Keyboard Shortcuts\u{2026}\u{201D}, select Services, expand Text, and tick \u{201C}Learn Word in Dictator\u{2026}\u{201D}.")
                Spacer()
                Button("Open System Settings") { openServicesSettings() }
                    .controlSize(.small)
            }
        }
        .font(.callout)
    }

    /// Bridges the store's mutable `entries` property to the toolbar/list
    /// helpers that expect a Binding. Writes flow through the store's
    /// debounced save path, so a stream of edits coalesces to one disk write.
    private var vocabBinding: Binding<[VocabularyEntry]> {
        Binding(get: { store.entries }, set: { store.entries = $0 })
    }

    private func countLabel(total: Int, shown: Int) -> String {
        if total == 0 { return "" }
        if shown == total {
            return total == 1 ? "1 entry" : "\(total) entries"
        }
        return "\(shown) of \(total)"
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ vocabulary: Binding<[VocabularyEntry]>) -> some View {
        let entries = vocabulary.wrappedValue
        if entries.isEmpty {
            ContentUnavailableView(
                "Your dictionary is empty",
                systemImage: "character.book.closed",
                description: Text("Use + in the toolbar. Example: github \u{2192} GitHub.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let visible = filteredEntries(from: entries)
            if visible.isEmpty {
                ContentUnavailableView.search(text: shell.dictionarySearch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { entry in
                            CompactDictionaryRow(
                                entry: entryBinding(id: entry.id, in: vocabulary),
                                focused: $focusedFieldID,
                                onChange: { state.save() },
                                onRemove: {
                                    vocabulary.wrappedValue.removeAll { $0.id == entry.id }
                                    state.save()
                                }
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.04))
                )
            }
        }
    }

    // MARK: - Filtering & sorting

    private func filteredEntries(from source: [VocabularyEntry]) -> [VocabularyEntry] {
        let q = shell.dictionarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [VocabularyEntry]
        if q.isEmpty {
            filtered = source
        } else {
            filtered = source.filter {
                $0.pattern.lowercased().contains(q) || $0.replacement.lowercased().contains(q)
            }
        }
        switch shell.dictionarySort {
        case .alphabetical:
            return filtered.sorted {
                $0.pattern.localizedCaseInsensitiveCompare($1.pattern) == .orderedAscending
            }
        case .asEntered:
            return filtered
        }
    }

    /// Binding that resolves an entry by id against the live source array.
    /// Necessary because `filteredEntries` returns a snapshot — editing a row
    /// needs to mutate the canonical store, not the snapshot.
    private func entryBinding(id: VocabularyEntry.ID,
                              in array: Binding<[VocabularyEntry]>) -> Binding<VocabularyEntry> {
        Binding(
            get: {
                array.wrappedValue.first { $0.id == id }
                    ?? VocabularyEntry(id: id, pattern: "", replacement: "")
            },
            set: { newValue in
                if let idx = array.wrappedValue.firstIndex(where: { $0.id == id }) {
                    array.wrappedValue[idx] = newValue
                }
            }
        )
    }
}

/// Single-line row optimised for dictionaries with many entries. Toggles
/// for "case-sensitive" and "whole word" become icon toggle-buttons that
/// only render the affordance — hover/help reveals the meaning. The
/// trash button fades in on hover so the row reads as data, not chrome.
private struct CompactDictionaryRow: View {
    @Binding var entry: VocabularyEntry
    @FocusState.Binding var focused: VocabularyEntry.ID?
    let onChange: () -> Void
    let onRemove: () -> Void

    @State private var hovering: Bool = false
    @FocusState private var localFocus: FocusedField?
    /// Shared across all rows so only one row can hold the mic at a time.
    @State private var tester = DictionaryTester.shared

    private enum FocusedField: Hashable { case pattern, replacement }

    var body: some View {
        HStack(spacing: 8) {
            micButton
            TextField("Heard", text: $entry.pattern)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .focused($localFocus, equals: .pattern)
                .onSubmit { onChange() }
                .onChange(of: entry.pattern) { _, _ in onChange() }
                .onChange(of: focused) { _, newID in
                    if newID == entry.id { localFocus = .pattern }
                }
                // .onChange doesn't fire if the row mounts *after* the
                // parent flips `focused` (which is what happens when Add
                // inserts a new row). Catch that case on appear.
                .onAppear {
                    if focused == entry.id { localFocus = .pattern }
                }

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))

            TextField("Replacement", text: $entry.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .focused($localFocus, equals: .replacement)
                .onSubmit { onChange() }
                .onChange(of: entry.replacement) { _, _ in onChange() }

            Toggle(isOn: $entry.caseSensitive) {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Case-sensitive: only match the exact casing typed in Heard.")
            .onChange(of: entry.caseSensitive) { _, _ in onChange() }

            Toggle(isOn: $entry.wholeWord) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Whole word only: don't match inside other words.")
            .onChange(of: entry.wholeWord) { _, _ in onChange() }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 0.85 : 0)
            .frame(width: 18)
            .help("Delete rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .onHover { hovering = $0 }
        // When the tester finishes a session for this row, drop the
        // transcript into the pattern field. Watching the rowID rather
        // than the whole struct keeps the onChange firing only when a
        // new result arrives.
        .onChange(of: tester.pendingResult?.rowID) { _, newID in
            guard newID == entry.id, let result = tester.pendingResult else { return }
            entry.pattern = result.text
            tester.consumePendingResult()
            onChange()
        }
    }

    /// Mic button that records a short clip and runs it through the
    /// configured ASR engine, populating this row's pattern field with
    /// whatever was heard. Useful when you know how a word should be
    /// spelled but don't know what Whisper or Parakeet actually
    /// produces — close the loop without leaving Settings.
    @ViewBuilder
    private var micButton: some View {
        let isThisRowActive = tester.activeRowID == entry.id
        Button {
            if isThisRowActive {
                tester.stop()
            } else {
                tester.start(for: entry.id)
            }
        } label: {
            micButtonIcon(isThisRowActive: isThisRowActive)
        }
        .buttonStyle(.borderless)
        .frame(width: 18)
        .help(isThisRowActive
              ? "Listening — click to stop"
              : "Record what Dictator hears and fill the Heard field")
    }

    @ViewBuilder
    private func micButtonIcon(isThisRowActive: Bool) -> some View {
        switch tester.state {
        case .warmingUp where isThisRowActive,
             .transcribing where isThisRowActive:
            ProgressView()
                .controlSize(.mini)
        case .recording where isThisRowActive:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.red)
        default:
            Image(systemName: "mic")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Subtle hover state so the row reads as interactive without
    /// surrounding every entry in a heavy card background. Focus also tints
    /// the row so the user can see which entry is being edited.
    private var rowBackground: Color {
        if localFocus != nil { return Color.accentColor.opacity(0.10) }
        if hovering           { return Color.secondary.opacity(0.10) }
        return .clear
    }
}
