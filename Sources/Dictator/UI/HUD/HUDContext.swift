import SwiftUI

/// Observable bridge from `DictationHUDController` (which knows the screen
/// and drives show/hide) to whichever HUD view is mounted. The controller
/// writes; the views read.
///
/// Dictation-only since Meetings moved into its own app — the meeting coach
/// has its own `CoachIslandContext` over there, driving a second panel built
/// from the same shared `IslandPanel` / `NotchGeometry` primitives.
@MainActor
@Observable
final class HUDContext {
    /// Notch facts for the screen the panel sits on. Read by the island
    /// style only; the bottom styles don't care about the top edge.
    var geometry = NotchGeometry(hasNotch: false, notchWidth: 0, topInset: 24)
    /// Drives the reveal animation: false = HUD tucked away (the island up
    /// behind the screen's top edge, the compact styles faded out below
    /// their rest position), true = out in view. Mutated only by the
    /// controller, inside withAnimation — and it doubles as the controller's
    /// source of truth for "is the HUD out", so there's no separate flag to
    /// desync.
    var revealed = false
}
