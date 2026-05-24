import SwiftUI
import UIKit

/// History list — newest first. Tap a row to copy the cleaned/delivered
/// transcript; long-press to access the raw (pre-cleanup) version too.
/// Swipe to delete a single entry; the toolbar's "Clear" button wipes
/// everything after a confirmation.
struct HistoryView: View {
    @Bindable var store: DictationHistoryStore = .shared
    @State private var confirmClear = false
    @State private var copiedID: UUID?
    @State private var copiedRawID: UUID?
    /// Entry whose raw transcript the user is currently inspecting via
    /// the detail sheet. Sheet driven by `item:` so a single state
    /// drives both presentation and dismissal.
    @State private var inspectedEntry: DictationHistoryEntry?

    /// Held strongly so the haptic doesn't lag on first tap.
    private let copyFeedback = UINotificationFeedbackGenerator()

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HistoryRow(
                            entry: entry,
                            justCopied: copiedID == entry.id,
                            justCopiedRaw: copiedRawID == entry.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            copy(entry)
                        }
                        // Long-press → context menu with cleaned vs raw
                        // copy actions and quick access to the side-by-
                        // side detail sheet. iOS shows the menu after
                        // a ~0.5s press; swipe-to-delete is unaffected.
                        .contextMenu {
                            Button {
                                copy(entry)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            if entry.hasRaw {
                                Button {
                                    copyRaw(entry)
                                } label: {
                                    Label("Copy raw transcript", systemImage: "waveform")
                                }
                                Button {
                                    inspectedEntry = entry
                                } label: {
                                    Label("Compare versions", systemImage: "rectangle.split.2x1")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                store.remove(id: entry.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.remove(id: store.entries[index].id)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmClear = true }
                }
            }
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every transcript from this device. It can't be undone.")
        }
        .sheet(item: $inspectedEntry) { entry in
            HistoryDetailSheet(entry: entry)
        }
    }

    private func copy(_ entry: DictationHistoryEntry) {
        UIPasteboard.general.string = entry.text
        copyFeedback.notificationOccurred(.success)
        copiedID = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if copiedID == entry.id {
                copiedID = nil
            }
        }
    }

    private func copyRaw(_ entry: DictationHistoryEntry) {
        guard let raw = entry.raw, !raw.isEmpty else { return }
        UIPasteboard.general.string = raw
        copyFeedback.notificationOccurred(.success)
        copiedRawID = entry.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if copiedRawID == entry.id {
                copiedRawID = nil
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No transcripts yet", systemImage: "text.bubble")
        } description: {
            Text("Hold the mic button on the main screen to record one. History keeps your last seven days.")
        }
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let entry: DictationHistoryEntry
    let justCopied: Bool
    let justCopiedRaw: Bool

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.body)
                .lineLimit(4)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(Self.relative.localizedString(for: entry.timestamp, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if entry.hasRaw {
                    // Subtle hint that a pre-cleanup version exists.
                    // Discoverability is otherwise zero — users wouldn't
                    // know to long-press without something signalling it.
                    Label("raw", systemImage: "waveform")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                if justCopiedRaw {
                    Label("Raw copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if justCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: justCopied)
        .animation(.easeInOut(duration: 0.18), value: justCopiedRaw)
    }
}

// MARK: - Detail sheet

private struct HistoryDetailSheet: View {
    let entry: DictationHistoryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(
                        title: "Final",
                        systemImage: "sparkles",
                        text: entry.text
                    )
                    if let raw = entry.raw, !raw.isEmpty {
                        section(
                            title: "Raw transcript",
                            systemImage: "waveform",
                            text: raw
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section(title: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
        }
    }
}
