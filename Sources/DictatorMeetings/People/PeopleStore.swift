import Foundation
import Observation

/// The cross-meeting people store: who the user meets with, keyed by voice.
/// Each post-processed meeting offers its speakers' embeddings here — a
/// match links the speaker to a known person (and applies their name); a
/// named stranger becomes a new person. `people.json` lives in synced
/// storage next to settings/history.
///
/// Matching is voice-only and deliberately conservative: a false merge
/// writes someone else's name on a speaker, which is worse than leaving
/// them anonymous. Embeddings are compared only within the same diarizer
/// model's space.
@MainActor
@Observable
final class PeopleStore {
    static let shared = PeopleStore()

    private(set) var people: [PersonRecord] = []

    /// Minimum cosine similarity to call two voices the same person across
    /// meetings. Same-session cross-track matching uses 0.78; across
    /// meetings/devices the same voice drifts more, but the cost of a wrong
    /// match is higher — 0.74 splits the difference until real multi-meeting
    /// data says otherwise.
    static let matchThreshold: Float = 0.74

    private static let filename = "people.json"

    private init() {
        load()
    }

    // MARK: - Matching & learning

    /// Every same-model person matching this voice at/above the threshold,
    /// best-first. The linker uses the FULL ranked list, not just the top:
    /// a person can be claimed by only one speaker per meeting, so a speaker
    /// whose best person is taken by a closer-matching speaker needs its
    /// next-best to fall back to rather than spawning a duplicate. Each
    /// person's score is its single closest stored sample (max, not mean —
    /// a match against any one environment counts).
    func matches(for embedding: [Float], modelID: String) -> [(person: PersonRecord, similarity: Float)] {
        var out: [(PersonRecord, Float)] = []
        for person in people where person.embeddingModelID == modelID {
            var best: Float = 0
            for stored in person.embeddings {
                best = max(best, MeetingProcessor.cosineSimilarity(embedding, stored))
            }
            if best >= Self.matchThreshold { out.append((person, best)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Skip storing an embedding this similar to one already held — a ninth
    /// near-identical desk-mic sample adds nothing, and under the k-recent
    /// cap it would eventually EVICT the rare different-environment sample
    /// (the car voice, the AirPods voice) that diversity exists to keep.
    private static let noveltyCeiling: Float = 0.92

    /// Fold a fresh observation of a known person's voice into their record.
    /// A model change resets the embedding set (old vectors live in a
    /// different space and would poison matching). Near-duplicates of an
    /// existing sample are skipped so the set stays DIVERSE — one person,
    /// many rooms/mics — rather than eight copies of their usual setup.
    func recordObservation(personID: String, embedding: [Float], modelID: String) {
        guard let idx = people.firstIndex(where: { $0.id == personID }) else { return }
        if people[idx].embeddingModelID != modelID {
            people[idx].embeddings = []
            people[idx].embeddingModelID = modelID
        }
        let novel = people[idx].embeddings.allSatisfy {
            MeetingProcessor.cosineSimilarity(embedding, $0) < Self.noveltyCeiling
        }
        guard novel || people[idx].embeddings.isEmpty else { return }
        people[idx].embeddings.append(embedding)
        if people[idx].embeddings.count > PersonRecord.maxEmbeddings {
            people[idx].embeddings.removeFirst(people[idx].embeddings.count - PersonRecord.maxEmbeddings)
        }
        people[idx].updatedAt = Date()
        save()
    }

    /// Everyone whose name matches (normalized, exact). Callers branch on
    /// count: exactly one is the name bridge — a known person's voice from a
    /// new room/mic misses the voice match, but their name links them, and
    /// the new environment's embedding gets stored so next time the VOICE
    /// matches directly. Zero means a genuine stranger (safe to create).
    /// Two or more is AMBIGUOUS — two distinct "Jack"s must neither
    /// auto-merge nor spawn a third record; name them apart and it resolves.
    func peopleMatching(name: String) -> [PersonRecord] {
        let key = Self.normalized(name)
        guard !key.isEmpty else { return [] }
        return people.filter { Self.normalized($0.name) == key }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func createPerson(name: String, embedding: [Float]?, modelID: String?) -> PersonRecord {
        let person = PersonRecord(
            name: name,
            embeddings: embedding.map { [$0] } ?? [],
            embeddingModelID: embedding != nil ? modelID : nil
        )
        people.append(person)
        save()
        return person
    }

    func person(id: String) -> PersonRecord? {
        people.first { $0.id == id }
    }

    func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = people.firstIndex(where: { $0.id == id }),
              people[idx].name != trimmed else { return }
        people[idx].name = trimmed
        people[idx].updatedAt = Date()
        save()
    }

    func attachEmail(id: String, email: String) {
        let normalized = email.lowercased()
        guard let idx = people.firstIndex(where: { $0.id == id }),
              !people[idx].emails.contains(normalized) else { return }
        people[idx].emails.append(normalized)
        people[idx].updatedAt = Date()
        save()
    }

    /// Fold one person into another — the fix for duplicate records of the
    /// same human (created before the name bridge existed, or by renaming
    /// onto a name someone already holds). Emails union; voice samples
    /// combine through the same novelty guard as live observation, but only
    /// when both sets share a model space — mixed-model vectors don't
    /// compare, so the target's set wins and the source's is dropped.
    /// The caller re-points past meetings (`MeetingsStore.repointPerson`);
    /// this store only knows about people.
    func merge(id sourceID: String, into targetID: String) {
        guard sourceID != targetID,
              let source = people.first(where: { $0.id == sourceID }),
              let dst = people.firstIndex(where: { $0.id == targetID }) else { return }
        for email in source.emails where !people[dst].emails.contains(email) {
            people[dst].emails.append(email)
        }
        if people[dst].embeddings.isEmpty, !source.embeddings.isEmpty {
            people[dst].embeddings = source.embeddings
            people[dst].embeddingModelID = source.embeddingModelID
        } else if people[dst].embeddingModelID == source.embeddingModelID {
            for embedding in source.embeddings {
                let novel = people[dst].embeddings.allSatisfy {
                    MeetingProcessor.cosineSimilarity(embedding, $0) < Self.noveltyCeiling
                }
                if novel { people[dst].embeddings.append(embedding) }
            }
            if people[dst].embeddings.count > PersonRecord.maxEmbeddings {
                people[dst].embeddings.removeFirst(people[dst].embeddings.count - PersonRecord.maxEmbeddings)
            }
        }
        people[dst].createdAt = min(people[dst].createdAt, source.createdAt)
        people[dst].updatedAt = Date()
        people.removeAll { $0.id == sourceID }
        save()
    }

    /// Per-person delete — removes the record AND its voice embeddings (the
    /// privacy contract for default-on recognition). Past meetings keep
    /// their text; their speakers' personID just dangles harmlessly.
    func delete(id: String) {
        people.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        let url = SyncedStorage.fileURL(for: Self.filename)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PeopleFile.self, from: data) else { return }
        people = file.people
    }

    private func save() {
        let url = SyncedStorage.fileURL(for: Self.filename)
        guard let data = try? JSONEncoder().encode(PeopleFile(people: people)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
