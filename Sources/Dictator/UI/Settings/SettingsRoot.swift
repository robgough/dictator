import SwiftUI
import AppKit
import Sparkle

/// The sidebar list, hosted by `SettingsWindowController` inside a real
/// `NSSplitViewItem(sidebarWithViewController:)` — the split item provides
/// the source-list material and full-height layout natively, so the list
/// hides its own background rather than hand-painting a blur.
struct SettingsSidebar: View {
    @Bindable var shell: SettingsShellModel

    var body: some View {
        List(SettingsSection.allCases, selection: Binding(
            get: { shell.section as SettingsSection? },
            // Coalesce: `List`'s selection binding is optional, but the
            // detail pane should never go blank.
            set: { shell.section = $0 ?? shell.section }
        )) { section in
            Label {
                Text(section.title)
            } icon: {
                SettingsSidebarIcon(systemImage: section.systemImage, tint: section.tint)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// The detail column, hosted by `SettingsWindowController`. Page titles and
/// per-pane controls live in the window's real toolbar (see SettingsShell),
/// so this is content only.
struct SettingsDetailRoot: View {
    let shell: SettingsShellModel
    let updater: SPUUpdater

    var body: some View {
        Group {
            switch shell.section {
            // Grouped-`Form` panes supply their own section insets — no extra
            // padding, they sit edge-to-edge in the detail column like System
            // Settings. The list / card panes relied on the old TabView's
            // outer `.padding(20)`, so they get it back here (Dictation adds
            // it per sub-pane, since its Modes tab is a grouped Form).
            case .general:    GeneralPane()
            case .dictation:  DictationPane(shell: shell)
            case .models:     ModelsPane(shell: shell)
            case .assistant:  AssistantPane()
            case .dictionary: DictionaryPane(shell: shell).settingsDetailPadding()
            case .about:      AboutPane(updater: updater).settingsDetailPadding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The six settings sections, in sidebar order. Identity is the case itself so
/// `List`'s data-driven selection binds straight to `SettingsSection?`.
///
/// Dictation folds the old Input / Modes / History sections into one section
/// with a toolbar segmented control (`SettingsShellModel.dictationTab`), the
/// same pattern Models already used for its three sub-panes.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, dictation, models, assistant, dictionary, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general:    "General"
        case .dictation:  "Dictation"
        case .models:     "Models"
        case .assistant:  "Assistant"
        case .dictionary: "Dictionary"
        case .about:      "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:    "gearshape.fill"
        case .dictation:  "mic.fill"
        case .models:     "cpu"
        case .assistant:  "wand.and.stars"
        case .dictionary: "character.book.closed.fill"
        case .about:      "info.circle.fill"
        }
    }

    /// Badge tint behind the white glyph. Picked to read as distinct, vaguely
    /// semantic chips (mic = blue, AI = pink…) rather than to match any system
    /// convention.
    var tint: Color {
        switch self {
        case .general:    .gray
        case .dictation:  .blue
        case .models:     .purple
        case .assistant:  .pink
        case .dictionary: .green
        case .about:      Color(red: 0.28, green: 0.46, blue: 0.62)   // slate blue — bright .cyan washes out the white glyph
        }
    }
}

/// The System-Settings-style sidebar badge: a white SF Symbol on a small
/// colour-filled rounded square.
private struct SettingsSidebarIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            // Scale-to-fit a fixed inner box rather than sizing by font: SF
            // Symbols have different aspect ratios, and wide glyphs overflow
            // a font-sized frame horizontally and spill past the badge. A
            // fixed fit box keeps every icon inside the badge with margin.
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}
