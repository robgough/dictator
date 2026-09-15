import SwiftUI

/// Asks before a tool runs.
///
/// The MCP specification is explicit that a client SHOULD keep a human in the
/// loop and SHOULD show the user a tool's *inputs* before the call, precisely
/// so a model talked into exfiltrating something gets caught here. So the
/// arguments are shown in full, not summarised, and "Always allow" is offered
/// per tool rather than per server — approving one tool on a server shouldn't
/// silently approve the other twenty it exposes.
struct ChatToolApprovalSheet: View {
    let pending: ChatEngine.PendingApproval
    let onApprove: (_ always: Bool) -> Void
    let onDeny: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run “\(pending.tool.displayName)”?")
                        .font(.headline)
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !pending.tool.detail.isEmpty {
                Text(pending.tool.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !argumentText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("With")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(argumentText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                }
            }

            HStack {
                Button("Don't Allow") {
                    onDeny()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                // Only offered for MCP tools. A built-in has a fixed, auditable
                // implementation and a once-per-call prompt for "read the
                // clipboard" would be maddening — but "always" for a
                // third-party server is a standing grant and deserves its own
                // deliberate click.
                if pending.tool.serverID != nil {
                    Button("Always Allow") {
                        onApprove(true)
                        dismiss()
                    }
                }
                Button("Allow") {
                    onApprove(false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var source: String {
        if let server = pending.tool.serverName {
            return "From the “\(server)” MCP server"
        }
        return "Built into Dictator"
    }

    private var argumentText: String {
        guard case .object(let fields) = pending.call.arguments, !fields.isEmpty else { return "" }
        return fields.keys.sorted()
            .map { "\($0): \(fields[$0]?.compactString ?? "")" }
            .joined(separator: "\n")
    }
}
