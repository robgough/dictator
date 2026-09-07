import SwiftUI

/// Mounts the HUD look for the current `hudStyle` setting inside the one
/// always-on-screen panel. Switching styles in Settings swaps the view tree
/// in place; `DictationHUDController` moves the panel to match.
struct DictationHUDRootView: View {
    @Environment(AppState.self) private var state
    let context: HUDContext

    var body: some View {
        switch state.settings.hudStyle {
        case .island:
            IslandView(context: context)
        case .islandSmall:
            IslandView(context: context, compact: true)
        case .pill:
            CompactHUDView(context: context, style: .pill)
        case .mini:
            CompactHUDView(context: context, style: .mini)
        }
    }
}
