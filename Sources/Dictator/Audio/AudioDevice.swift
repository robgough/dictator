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

    /// Reserved UID for the synthetic "System default" entry — when this is
    /// the top-most "connected" device in the priority list, Dictator defers
    /// to whatever input macOS's Sound preferences currently point at,
    /// rather than pinning a specific hardware device.
    static let systemDefaultUID = "__dictator.system_default__"

    /// The synthetic "System default" entry that always appears in the
    /// priority list. Always reports as connected (there's always a system
    /// default) and can't be forgotten.
    static let systemDefault = AudioDevice(
        uid: AudioDevice.systemDefaultUID,
        name: "System default",
        manufacturer: nil,
        lastSeen: .distantPast
    )

    /// Convenience — for UI special-casing (hiding the forget button,
    /// substituting a static subtitle, etc.).
    var isSystemDefault: Bool { uid == AudioDevice.systemDefaultUID }
}
