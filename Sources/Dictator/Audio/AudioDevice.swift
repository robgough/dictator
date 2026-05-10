import Foundation

struct AudioDevice: Identifiable, Codable, Equatable, Hashable, Sendable {
    let uid: String
    var name: String
    var manufacturer: String?
    var lastSeen: Date

    var id: String { uid }

    init(uid: String, name: String, manufacturer: String?, lastSeen: Date = Date()) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.lastSeen = lastSeen
    }
}
