import Foundation
import AppKit

enum TriggerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keyboardShortcut
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case leftControl
    case rightControl
    case leftShift
    case rightShift
    case fn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keyboardShortcut: "Keyboard combination"
        case .leftOption:       "Left Option (⌥)"
        case .rightOption:      "Right Option (⌥)"
        case .leftCommand:      "Left Command (⌘)"
        case .rightCommand:     "Right Command (⌘)"
        case .leftControl:      "Left Control (⌃)"
        case .rightControl:     "Right Control (⌃)"
        case .leftShift:        "Left Shift (⇧)"
        case .rightShift:       "Right Shift (⇧)"
        case .fn:               "fn"
        }
    }

    /// The macOS virtual key code for the underlying physical key.
    /// `nil` for `.keyboardShortcut` which uses KeyboardShortcuts instead.
    var keyCode: UInt16? {
        switch self {
        case .keyboardShortcut: nil
        case .leftCommand:      0x37
        case .rightCommand:     0x36
        case .leftShift:        0x38
        case .rightShift:       0x3C
        case .leftOption:       0x3A
        case .rightOption:      0x3D
        case .leftControl:      0x3B
        case .rightControl:     0x3E
        case .fn:               0x3F
        }
    }

    /// The NSEvent modifier flag asserted by the chosen key.
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .keyboardShortcut: nil
        case .leftCommand, .rightCommand: .command
        case .leftShift, .rightShift:     .shift
        case .leftOption, .rightOption:   .option
        case .leftControl, .rightControl: .control
        case .fn:                          .function
        }
    }
}
