import Foundation

/// A reusable bundle of checklist items layered onto a meeting's checklist
/// at record start — the "client type B needs these points" dimension that
/// the meeting type alone can't carry. Multi-selectable in the pre-record
/// sheet; persisted in settings (synced) like custom meeting types.
///
/// Future (`meeting-context.md`): profiles gain links into the people store
/// so the right profile auto-suggests when matched attendees join.
struct CoachChecklistProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String       // slug, MeetingTypeDefinition.makeID-style
    var name: String     // "Client type B", "Acme account"
    var items: [String]
    /// Raw `CoachNudge.Kind` values this set arms when added to a meeting —
    /// a discovery set wants `askQuestion` armed, not just its items listed.
    /// nil/empty = checklist only.
    var armedNudges: [String]?

    init(id: String, name: String, items: [String], armedNudges: [String]? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.armedNudges = armedNudges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.items = try c.decodeIfPresent([String].self, forKey: .items) ?? []
        self.armedNudges = try c.decodeIfPresent([String].self, forKey: .armedNudges)
    }

    private enum CodingKeys: String, CodingKey { case id, name, items, armedNudges }
}
