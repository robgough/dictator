import ActivityKit
import AppIntents
import Foundation

/// The Live Activity Dictator shows while it's holding the mic — a recording
/// in progress, or a warm background session the keyboard can dictate into.
/// It's the visible half of the `audio` background mode: the lit mic
/// indicator says *something* is listening, and this says what, for how
/// long, and gives a one-tap way to stop it.
///
/// Compiled into both the app and the `DictatorLiveActivity` widget
/// extension (see project.yml): the widget renders it, the app starts,
/// updates and ends it.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// Warm mic, nothing being kept.
            case ready
            case recording
            case transcribing
        }

        var phase: Phase
        /// When the warm mic is released if unused. nil when there's no
        /// session behind this recording (the setting is off), so the
        /// activity ends with the recording.
        var expiresAt: Date?
        /// Drives the running timer while recording.
        var recordingStartedAt: Date?
        /// First words of the last result, so the lock screen confirms what
        /// went onto the clipboard.
        var lastSnippet: String?
    }
}

extension Notification.Name {
    /// Posted in the app process by the Live Activity's buttons. The object
    /// is a `DictationActivityCommand` raw value.
    static let dictationActivityCommand = Notification.Name("DictatorIOS.dictationActivityCommand")
}

enum DictationActivityCommand: String {
    case toggle
    case end
}

/// Start or stop a dictation from the Live Activity. A `LiveActivityIntent`
/// runs in the app's process, so it reaches the warm recorder directly; the
/// result lands on the clipboard, since there's no text field to type into.
struct ToggleDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start or Stop Dictation"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .dictationActivityCommand, object: DictationActivityCommand.toggle.rawValue)
        }
        return .result()
    }
}

/// Release the warm mic now.
struct EndDictationSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off Microphone"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .dictationActivityCommand, object: DictationActivityCommand.end.rawValue)
        }
        return .result()
    }
}
