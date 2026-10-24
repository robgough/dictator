import SwiftUI

/// The two record colours, shared by the app and the keyboard extension
/// (which compiles this file by path, see project.yml).
extension Color {
    /// Speaking: the mic and a dictation in progress.
    static let dictatorSpeak = Color(red: 0xE5 / 255, green: 0x38 / 255, blue: 0x3B / 255)
    /// Assist: a spoken instruction in progress.
    static let dictatorAssist = Color(red: 0x6A / 255, green: 0x4B / 255, blue: 0xE0 / 255)
}
