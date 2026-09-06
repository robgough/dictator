import SwiftUI
import AppKit

/// Dictation → History: the rolling record of recent dictations, with each
/// pipeline stage expandable so a surprising result can be traced back to the
/// step that caused it.
struct HistoryPane: View {
    @State private var history = DictationHistory.shared
    @State private var expanded: UUID?
    /// The Clear button lives in the window toolbar (SettingsShell) and only
    /// on this tab; the toolbar sets `confirmHistoryClear` and this pane
    /// presents the destructive confirmation.
    @Bindable var shell: SettingsShellModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history.records.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Recorded dictations will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(history.records) { record in
                            HistoryRow(
                                record: record,
                                isExpanded: expanded == record.id,
                                toggle: {
                                    expanded = expanded == record.id ? nil : record.id
                                },
                                remove: {
                                    history.remove(id: record.id)
                                    if expanded == record.id { expanded = nil }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                // Count lives here, not in the toolbar — bare text as a
                // toolbar item gets a liquid-glass capsule on macOS 26.
                SectionFootnote("\(history.records.count) kept; 7 days, 500 max.")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $shell.confirmHistoryClear) {
            Button("Clear", role: .destructive) {
                history.clear()
                expanded = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded dictation. The dictation feature itself is unaffected.")
        }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let isExpanded: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    // Clipboard-only is a normal outcome, not a problem — keep it
                    // neutral. Orange is reserved for things that actually went wrong.
                    Image(systemName: record.pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        .foregroundStyle(record.pasted ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.final)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(Self.formatted(record.timestamp))
                            Text("·")
                            Text(record.inputDevice)
                            if let style = record.style {
                                Text("·")
                                Text(style)
                            }
                            if let note = record.note {
                                Text("·")
                                Text(note)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedStages
                HStack {
                    Spacer()
                    Button(role: .destructive, action: remove) {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private var expandedStages: some View {
        VStack(alignment: .leading, spacing: 6) {
            stageRow(label: "Raw (Whisper)", text: record.raw)
            if let stages = record.stages, !stages.isEmpty {
                // New-style record: the pipeline's ordered passes, by name.
                ForEach(stages, id: \.self) { stage in
                    stageRow(label: stage.name, text: stage.text)
                }
                if let c = record.dictionaryCorrected {
                    stageRow(label: "Dictionary-corrected", text: c)
                }
                if record.final != stages.last!.text {
                    stageRow(label: "Final (delivered)", text: record.final)
                }
            } else {
                // Legacy record (predates the ordered-stages model).
                if let f = record.formatted, f != record.raw {
                    stageRow(label: "Formatted", text: f)
                }
                if let c = record.dictionaryCorrected {
                    stageRow(label: "Dictionary-corrected", text: c)
                }
                if let t = record.tidied {
                    stageRow(label: "Grammar-tidied", text: t)
                }
                if let r = record.restructured {
                    stageRow(label: "Restructured", text: r)
                }
                if record.final != (record.restructured ?? record.tidied ?? record.dictionaryCorrected ?? record.formatted ?? record.raw) {
                    stageRow(label: "Final (delivered)", text: record.final)
                }
            }
        }
        .padding(.top, 4)
    }

    private func stageRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this stage")
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
    }

    private static func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
