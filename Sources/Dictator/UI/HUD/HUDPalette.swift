import SwiftUI

// Literal RGB tints for the non-blue HUD accents, shared by every HUD style.
// We deliberately don't use SwiftUI's semantic colours (`.indigo`, `.purple`,
// `.pink`, `.teal`, `.orange`) here: those are dynamic and re-resolve under a
// visual-effect view's vibrancy appearance, which itself shifts with the
// window content behind the HUD — so the icons and status text would drift
// in colour as the user moved the HUD over different apps (the bottom pill
// sits on `.regularMaterial`, exactly that situation). The HUD's blue reuses
// `Color.brandBlue` (BrandColors.swift).
extension Color {
    static let hudIndigo = Color(red: 0.369, green: 0.361, blue: 0.902) // ~#5E5CE6
    static let hudPurple = Color(red: 0.749, green: 0.353, blue: 0.949) // ~#BF5AF2
    static let hudPink   = Color(red: 1.0,   green: 0.216, blue: 0.373) // ~#FF375F
    static let hudTeal   = Color(red: 0.392, green: 0.824, blue: 1.0)   // ~#64D2FF
    static let hudOrange = Color(red: 1.0,   green: 0.624, blue: 0.039) // ~#FF9F0A
}
