import Foundation

/// One person the user has met with — the unit of cross-meeting identity.
/// Voice embeddings let the diarizer's anonymous "Speaker 2" resolve to
/// "Jack" in the next meeting; names/emails come from speaker renames,
/// inference, and calendar attendees. Lives in `people.json` (synced).
struct PersonRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String                 // UUID string
    var name: String
    var emails: [String]
    /// Recent voice embeddings (newest last, capped) — multiple samples
    /// rather than one centroid, so the same person on AirPods and on a
    /// desk mic both stay matchable.
    var embeddings: [[Float]]
    /// The diarizer model that produced the embeddings. Embeddings from a
    /// different model live in a different space — matching only compares
    /// same-model vectors, and a model upgrade naturally re-learns voices.
    var embeddingModelID: String?
    var createdAt: Date
    var updatedAt: Date

    static let maxEmbeddings = 8

    init(
        id: String = UUID().uuidString,
        name: String,
        emails: [String] = [],
        embeddings: [[Float]] = [],
        embeddingModelID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emails = emails
        self.embeddings = embeddings
        self.embeddingModelID = embeddingModelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        self.embeddings = try c.decodeIfPresent([[Float]].self, forKey: .embeddings) ?? []
        self.embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, emails, embeddings, embeddingModelID, createdAt, updatedAt
    }
}

/// `people.json` on disk.
struct PeopleFile: Codable, Equatable, Sendable {
    var people: [PersonRecord]
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(people: [PersonRecord] = [], schemaVersion: Int = PeopleFile.currentSchemaVersion) {
        self.people = people
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.people = try c.decodeIfPresent([PersonRecord].self, forKey: .people) ?? []
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey { case people, schemaVersion }
}
