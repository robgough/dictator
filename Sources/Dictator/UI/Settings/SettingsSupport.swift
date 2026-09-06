import SwiftUI
import AppKit

// Small pieces shared by more than one Settings pane. Anything that belongs
// to a single pane lives next to that pane instead.

extension View {
    /// Outer inset for detail panes that aren't grouped `Form`s. Grouped forms
    /// bring their own insets; the list / card panes used to inherit this from
    /// the old TabView's `.padding(20)`.
    func settingsDetailPadding() -> some View {
        padding(20)
    }
}

/// Connected / disconnected dot used by the microphone device list.
struct StatusDot: View {
    let connected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(connected ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                .frame(width: 20, height: 20)
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
        }
        .accessibilityLabel(connected ? "Connected" : "Disconnected")
    }
}

/// Wraps `SettingsShellModel.modeEditorID` for `.sheet(item:)`, which needs an
/// `Identifiable` payload — a bare `UUID?` can't be one without a retroactive
/// conformance we don't want to ship.
struct ModeEditorTarget: Identifiable {
    let id: UUID
}

/// Approximate model size, in the same GB/MB convention the model catalog
/// quotes. Shared by `ModelRow` and its confirmation dialogs.
func formatModelSize(_ mb: Int) -> String {
    if mb >= 1000 {
        return String(format: "%.1f GB", Double(mb) / 1000.0)
    }
    return "\(mb) MB"
}
