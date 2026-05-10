import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var history = DictationHistory.shared
    @State private var justCopied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRow

            if !history.records.isEmpty {
                Divider()
                recentList
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var recentList: some View {
        Text("Recent")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(history.mostRecent(10)) { record in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.final, forType: .string)
                    justCopied = record.id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(800))
                        if justCopied == record.id { justCopied = nil }
                    }
                } label: {
                    RecentRow(record: record, copied: justCopied == record.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.and.signal.meter.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("Dictator")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Hold the hotkey to dictate")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.pipeline.state.iconName)
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            if state.pipeline.state.isActive {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch state.pipeline.state {
        case .idle: "Idle"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .formatting: "Formatting…"
        case .fixingGrammar: "Tidying grammar…"
        case .restructuring: "Structuring…"
        case .done(_, let pasted, _): pasted ? "Pasted" : "Copied to clipboard"
        case .failed(let m): m
        }
    }

}

private struct RecentRow: View {
    let record: DictationRecord
    let copied: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: copied ? "checkmark.circle.fill" : (record.pasted ? "doc.on.doc" : "doc.on.clipboard"))
                .foregroundStyle(copied ? .green : (record.pasted ? .secondary : .orange))
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.final)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Text(Self.relative(record.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(copied ? Color.green.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
