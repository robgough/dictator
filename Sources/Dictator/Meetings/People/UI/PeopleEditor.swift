import SwiftUI

/// Manage the people store: rename (propagates to future matches), see what
/// the store knows (emails, voice-sample count), merge duplicate records of
/// the same human (right-click), and delete — which purges the person's
/// voice embeddings, the privacy valve for default-on recognition.
struct PeopleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PeopleStore.shared
    @State private var pendingMerge: PendingMerge?

    /// A merge the user has picked but not yet confirmed. Confirmation is
    /// deliberate where the speaker-chip merge has none: a wrong speaker
    /// merge mislabels one meeting, a wrong person merge mixes two humans'
    /// voice samples and mis-names people in every future meeting.
    private struct PendingMerge: Identifiable {
        let source: PersonRecord
        let target: PersonRecord
        var id: String { source.id + target.id }
    }

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
        .alert(item: $pendingMerge) { merge in
            Alert(
                title: Text("Merge “\(merge.source.name)” into “\(merge.target.name)”?"),
                message: Text("Their emails and voice samples are combined into one person, and past meetings carry over. This can't be undone."),
                primaryButton: .destructive(Text("Merge")) {
                    store.merge(id: merge.source.id, into: merge.target.id)
                    MeetingsStore.shared.repointPerson(from: merge.source.id, to: merge.target.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func row(_ person: PersonRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    TextField("Name", text: Binding(
                        get: { person.name },
                        set: { store.rename(id: person.id, to: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    if store.peopleMatching(name: person.name).count > 1 {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Another person has this name. Same-named people are never matched by name automatically — if they're the same person, right-click to merge; if not, rename one of them apart.")
                    }
                }
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
        .contextMenu {
            // Same idiom as the speaker chips — and like there, an empty
            // builder would mean no menu at all, so always show something.
            let targets = store.people.filter { $0.id != person.id }
            if !targets.isEmpty {
                Menu("Merge into") {
                    ForEach(targets) { target in
                        Button(mergeTargetLabel(target)) {
                            pendingMerge = PendingMerge(source: person, target: target)
                        }
                    }
                }
                .help("Combines this person's emails and voice samples into the one you pick — for when the same human ended up as two records.")
            } else {
                Button("Merge into… (no other people)") {}
                    .disabled(true)
            }
        }
    }

    /// Disambiguates same-named targets in the merge menu — two plain
    /// "Jack" entries would be a coin flip.
    private func mergeTargetLabel(_ person: PersonRecord) -> String {
        if let email = person.emails.first {
            return "\(person.name) — \(email)"
        }
        let n = person.embeddings.count
        return "\(person.name) — \(n) voice sample\(n == 1 ? "" : "s")"
    }
}
