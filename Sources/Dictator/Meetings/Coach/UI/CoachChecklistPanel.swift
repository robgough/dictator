import SwiftUI

/// The live checklist: rows tick off as the watcher (or a click) marks them
/// covered, ad-hoc items get a dismiss control, and the quick-add field
/// captures mid-meeting "don't let me forget" items. Used in the live
/// recording pane and inside the island's expanded state — semantic colours
/// only, so it reads correctly on both light cards and the black island.
struct CoachChecklistPanel: View {
    let engine: MeetingCoachEngine
    var compact = false

    @State private var newItemText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            ForEach(engine.checklist.filter { $0.status != .dismissed }) { entry in
                row(entry)
            }
            quickAdd
        }
    }

    private func row(_ entry: CoachChecklistEntry) -> some View {
        HStack(spacing: 7) {
            Button {
                engine.toggleDone(id: entry.id)
            } label: {
                Image(systemName: entry.isPending ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(entry.isPending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
                    .font(.system(size: compact ? 12 : 14))
            }
            .buttonStyle(.plain)

            Text(entry.text)
                .font(.system(size: compact ? 11 : 12))
                .strikethrough(!entry.isPending)
                .foregroundStyle(entry.isPending ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(2)

            if entry.source == .adhoc, entry.isPending {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Added mid-meeting — the coach will remind you until it's covered")
            }
            Spacer(minLength: 0)
            if entry.isPending {
                Button {
                    engine.dismissItem(id: entry.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Never mind — drop without counting as missed")
            }
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.tertiary)
            TextField("Add something to cover…", text: $newItemText)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 11 : 12))
                .onSubmit {
                    engine.addAdHocItem(newItemText)
                    newItemText = ""
                }
        }
    }
}
