import AppKit
import SwiftUI

/// Floating popup that lets the user add a vocabulary rule from outside
/// the Settings window — either via the Services menu (`LearnWordProvider`)
/// or via the App Intent (`LearnWordIntent`). Both entry points hand off
/// to `present(prefill:)` with whatever string the user had selected.
///
/// The "Treat selection as" picker is the load-bearing UX bit: the
/// selected text is sometimes the *correct* spelling (user wants Dictator
/// to substitute it for what it keeps mishearing) and sometimes the
/// *misheard* form (user spotted a bad transcript and wants to correct
/// it). Default is "Replace with" — it's the more common motion of "I
/// just typed the brand name properly, learn this spelling".
@MainActor
final class LearnWordPanelController: NSObject, NSWindowDelegate {
    static let shared = LearnWordPanelController()

    private var window: NSWindow?

    private override init() {}

    func present(prefill text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = ensureWindow()
        let root = LearnWordPanelView(
            prefill: trimmed,
            onSave: { [weak self] entry, replacingID in
                self?.applyEntry(entry, replacingID: replacingID)
                self?.window?.performClose(nil)
            },
            onCancel: { [weak self] in
                self?.window?.performClose(nil)
            }
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Learn Word"
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func applyEntry(_ entry: VocabularyEntry, replacingID: UUID?) {
        let store = VocabularyStore.shared
        if let replacingID, let idx = store.entries.firstIndex(where: { $0.id == replacingID }) {
            store.entries[idx] = entry
        } else {
            store.entries.append(entry)
        }
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        window = w
        return w
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Nothing to clear — the SwiftUI view owns its own state and a
        // fresh one is built on every `present(prefill:)`.
    }
}

// MARK: - View

private enum SelectionRole: String, CaseIterable, Identifiable {
    case replacement
    case pattern
    var id: String { rawValue }
    var label: String {
        switch self {
        case .replacement: "Replace with (correct spelling)"
        case .pattern:     "Heard (what Dictator gets wrong)"
        }
    }
}

private struct LearnWordPanelView: View {
    let prefill: String
    let onSave: (VocabularyEntry, UUID?) -> Void
    let onCancel: () -> Void

    @State private var role: SelectionRole = .replacement
    @State private var pattern: String = ""
    @State private var replacement: String = ""
    @State private var caseSensitive: Bool = false
    @State private var wholeWord: Bool = true

    /// Existing entry that matches the current `pattern` (case-insensitive,
    /// trimmed). When set, Save updates that entry instead of appending.
    private var existingMatch: VocabularyEntry? {
        let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return VocabularyStore.shared.entries.first {
            $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    private var canSave: Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !p.isEmpty && !r.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rolePicker
            fields
            toggles
            if let match = existingMatch, match.replacement != replacement {
                duplicateNote(match: match)
            }
            footer
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { applyRolePrefill() }
        .onChange(of: role) { _, _ in applyRolePrefill() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add to Dictator's dictionary")
                .font(.headline)
            Text("Applied right after the formatter pass, before the LLM.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var rolePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Treat selection as")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $role) {
                ForEach(SelectionRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var fields: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heard").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. github", text: $pattern)
                    .textFieldStyle(.roundedBorder)
            }
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replace with").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. GitHub", text: $replacement)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var toggles: some View {
        HStack(spacing: 16) {
            Toggle("Case-sensitive", isOn: $caseSensitive)
            Toggle("Whole word only", isOn: $wholeWord)
            Spacer()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.caption)
    }

    private func duplicateNote(match: VocabularyEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
            Text("A rule for \u{201C}\(match.pattern)\u{201D} already exists (\u{2192} \u{201C}\(match.replacement)\u{201D}). Saving will update it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(existingMatch != nil ? "Update" : "Save") {
                let entry = VocabularyEntry(
                    id: existingMatch?.id ?? UUID(),
                    pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacement: replacement.trimmingCharacters(in: .whitespacesAndNewlines),
                    caseSensitive: caseSensitive,
                    wholeWord: wholeWord
                )
                onSave(entry, existingMatch?.id)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
    }

    /// Move the prefill into whichever field matches the user's chosen
    /// role, clearing the other field only when it still holds a previous
    /// prefill we put there ourselves. We can't tell the difference once
    /// the user has edited, so be conservative: only auto-swap on the
    /// initial drop and clear behaviour kicks in only if the other field
    /// equals the prefill verbatim.
    private func applyRolePrefill() {
        switch role {
        case .replacement:
            if replacement.isEmpty { replacement = prefill }
            if pattern == prefill { pattern = "" }
        case .pattern:
            if pattern.isEmpty { pattern = prefill }
            if replacement == prefill { replacement = "" }
        }
    }
}
