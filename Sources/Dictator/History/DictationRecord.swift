import Foundation

struct DictationRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date

    /// Raw Whisper output.
    let raw: String
    /// Output of pass 1 (formatter). nil if that pass didn't run.
    let formatted: String?
    /// After applying the user's dictionary. nil if no entries matched.
    let dictionaryCorrected: String?
    /// Output of optional pass 2 (grammar). nil if disabled or rejected.
    let tidied: String?
    /// Output of optional pass 3 (structure). nil if disabled or rejected.
    let restructured: String?
    /// What we actually delivered to the user (pasted or copied).
    let final: String

    /// True if synthetic ⌘V paste was attempted (Accessibility granted).
    let pasted: Bool
    let inputDevice: String
    let note: String?
}
