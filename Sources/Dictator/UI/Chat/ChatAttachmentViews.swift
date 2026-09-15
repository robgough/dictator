import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An attachment waiting to be sent, or one that already has been.
///
/// Deliberately small. A file the *assistant* wrote is the outcome of the
/// conversation and gets `ChatFileCard` — a preview, a border, somewhere to
/// send it. A file the *user* attached is an input they already have: they
/// know what's in it, and a full card for each one would push the reply they
/// asked for off the screen.
struct ChatAttachmentChip: View {
    let attachment: ChatAttachment
    /// nil once sent — a chip in the transcript can't be taken back.
    var onRemove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(unreadable ? .orange : .secondary)
                    .lineLimit(1)
            }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(hovering ? 0.55 : 0.35), in: .rect(cornerRadius: 8))
        .frame(maxWidth: 240, alignment: .leading)
        .onHover { hovering = $0 }
        .help(helpText)
        .onTapGesture(count: 2) {
            guard attachment.stillExists else { return }
            NSWorkspace.shared.open(attachment.url)
        }
    }

    private var unreadable: Bool { attachment.text?.isEmpty ?? true }

    /// Says plainly whether the assistant can actually read it. An attachment
    /// that was silently ignored is the worst outcome here — the user asks
    /// about a scanned PDF and gets a confident answer about nothing.
    private var subtitle: String {
        if let note = attachment.note { return note }
        if attachment.truncated { return "\(attachment.sizeDescription) · first part read" }
        return attachment.sizeDescription
    }

    private var helpText: String {
        attachment.stillExists
            ? "\(attachment.name) — in this chat's folder. Double-click to open."
            : "\(attachment.name) — no longer on disk."
    }
}

/// The chips above the message box, before sending.
struct ChatPendingAttachments: View {
    let attachments: [ChatAttachment]
    let busyCount: Int
    let onRemove: (ChatAttachment) -> Void

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(attachments) { attachment in
                ChatAttachmentChip(attachment: attachment) { onRemove(attachment) }
            }
            if busyCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busyCount == 1 ? "Reading…" : "Reading \(busyCount) files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }
        }
    }
}

/// Wraps its children onto as many lines as they need.
///
/// `LazyVGrid` can't do this — it wants fixed columns, and a filename chip is
/// as wide as its filename. Four attachments of wildly different name lengths
/// otherwise leave half the row empty.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
