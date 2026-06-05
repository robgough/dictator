import Foundation

/// Identifier for the conversational shape of a meeting (1-on-1, stand-up,
/// retro, a user-defined custom type, …). Persisted on `MeetingMeta` /
/// `MeetingNotes` and resolved to a full `MeetingTypeDefinition` (display
/// name, notes template) by the macOS-side `MeetingTypeRegistry`.
///
/// Deliberately a string wrapper rather than an enum: meeting types are
/// user-extensible, and a raw-value enum THROWS when decoding an unknown
/// string — which would make the whole `meta.json` fail to decode and the
/// meeting silently vanish from the sidebar the moment its custom type was
/// deleted. A bare string round-trips any id losslessly; "what does this id
/// mean now?" is answered at the registry layer, never at decode.
///
/// The built-in ids below match the case names of the retired `MeetingType`
/// enum exactly ("oneOnOne", "teamMeeting", …) so every existing meta.json
/// keeps resolving without migration.
public struct MeetingTypeID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    // Built-in ids. `auto` doubles as "let the model decide" and the
    // fall-through when the user hasn't picked; `other` is the deliberate
    // "don't bias" choice (and the resolver's fallback for unknown ids).
    public static let auto          = MeetingTypeID("auto")
    public static let oneOnOne      = MeetingTypeID("oneOnOne")
    public static let standup       = MeetingTypeID("standup")
    public static let teamMeeting   = MeetingTypeID("teamMeeting")
    public static let planning      = MeetingTypeID("planning")
    public static let retrospective = MeetingTypeID("retrospective")
    public static let interview     = MeetingTypeID("interview")
    public static let clientCall    = MeetingTypeID("clientCall")
    public static let brainstorm    = MeetingTypeID("brainstorm")
    public static let lecture       = MeetingTypeID("lecture")
    public static let conversation  = MeetingTypeID("conversation")
    public static let other         = MeetingTypeID("other")
}
