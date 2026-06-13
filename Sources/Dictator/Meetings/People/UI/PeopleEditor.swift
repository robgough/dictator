import SwiftUI

/// Manage the people store: rename (propagates to future matches), see what
/// the store knows (emails, voice-sample count), and delete — which purges
/// the person's voice embeddings, the privacy valve for default-on
/// recognition.
struct PeopleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PeopleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People")
                .font(.title3.weight(.semibold))

            if store.people.isEmpty {
                Text("Nobody yet. People appear here as meetings are processed — a named speaker's voice is remembered, so they're recognised next time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.people) { person in
                            row(person)
                        }
                    }
                }
                .frame(height: 240)
            }

            HStack {
                Text("Deleting a person removes their stored voice. Past meeting transcripts are unaffected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func row(_ person: PersonRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: Binding(
                    get: { person.name },
                    set: { store.rename(id: person.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if !person.emails.isEmpty {
                        Text(person.emails.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(person.embeddings.count) voice sample\(person.embeddings.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                store.delete(id: person.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Forget this person and their stored voice")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
