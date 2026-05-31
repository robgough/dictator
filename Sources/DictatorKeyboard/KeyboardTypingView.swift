import SwiftUI

/// A basic, self-contained QWERTY keyboard shown when the user has **not**
/// granted Full Access. Everything here drives the text document proxy
/// (`insertText` / `deleteBackward`) only — no clipboard, no App Group, no
/// network — so it works without Full Access and satisfies App Review
/// guideline 4.4.1 ("the extension must provide functionality with and
/// without Full Access"). Dictation still needs Full Access (the keyboard
/// can't reach the mic or the host app without it), so a slim banner points
/// the user at Settings; the dictation pad (`KeyboardRootView`) replaces this
/// view the moment Full Access is on.
struct KeyboardTypingView: View {
    /// Insert a string at the cursor (a cased letter, digit, symbol, or space).
    let onInsert: (String) -> Void
    /// Backspace press / release — the controller runs the same hold-to-repeat
    /// timer it uses for the dictation pad's backspace.
    let onDeletePress: () -> Void
    let onDeleteRelease: () -> Void
    let onReturn: () -> Void
    /// Advance to the next keyboard (globe key).
    let onNextKeyboard: () -> Void
    /// Whether to show the globe key at all — hidden when Dictator is the only
    /// keyboard installed (iOS' `needsInputModeSwitchKey` is false), where the
    /// key would do nothing.
    let showsNextKeyboard: Bool

    private enum Plane { case letters, numbers, symbols }
    private enum ShiftState { case off, oneShot, locked }
    private enum Key {
        case char(String)
        case shift
        case backspace
        case toLetters   // "ABC"
        case toNumbers   // "123"
        case toSymbols   // "#+="
    }

    @State private var plane: Plane = .letters
    @State private var shift: ShiftState = .off

    var body: some View {
        VStack(spacing: 8) {
            banner
            ForEach(Array(topRows().enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        topKey(key)
                    }
                }
            }
            bottomRow
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.slash.fill")
                .font(.caption2)
            Text("Turn on Full Access in Settings to dictate")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .padding(.horizontal, 2)
        .accessibilityLabel("Turn on Full Access in Settings to use dictation")
    }

    // MARK: - Layout

    private func topRows() -> [[Key]] {
        switch plane {
        case .letters:
            return [
                ["q","w","e","r","t","y","u","i","o","p"].map(Key.char),
                ["a","s","d","f","g","h","j","k","l"].map(Key.char),
                [.shift] + ["z","x","c","v","b","n","m"].map(Key.char) + [.backspace],
            ]
        case .numbers:
            return [
                ["1","2","3","4","5","6","7","8","9","0"].map(Key.char),
                ["-","/",":",";","(",")","$","&","@","\""].map(Key.char),
                [.toSymbols] + [".",",","?","!","'"].map(Key.char) + [.backspace],
            ]
        case .symbols:
            return [
                ["[","]","{","}","#","%","^","*","+","="].map(Key.char),
                ["_","\\","|","~","<",">","€","£","¥","•"].map(Key.char),
                [.toNumbers] + [".",",","?","!","'"].map(Key.char) + [.backspace],
            ]
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            // Plane toggle: from letters → 123; from numbers/symbols → ABC.
            specialCap(label: plane == .letters ? "123" : "ABC", width: 48) {
                plane = (plane == .letters) ? .numbers : .letters
            }
            if showsNextKeyboard {
                specialCap(systemImage: "globe", width: 44, action: onNextKeyboard)
            }
            // Space — flexes to fill the row.
            Button(action: { onInsert(" ") }) {
                Text("space")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .background(capShape.fill(Color(.systemBackground)))
            }
            .buttonStyle(KeyCapStyle())
            .accessibilityLabel("Space")

            specialCap(label: "return", width: 74, action: onReturn)
        }
    }

    // MARK: - Key views

    @ViewBuilder
    private func topKey(_ key: Key) -> some View {
        switch key {
        case .char(let c):
            let cased = (plane == .letters && shift != .off) ? c.uppercased() : c
            Button {
                onInsert(cased)
                if shift == .oneShot { shift = .off }
            } label: {
                Text(cased)
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .background(capShape.fill(Color(.systemBackground)))
            }
            .buttonStyle(KeyCapStyle())

        case .shift:
            Button { cycleShift() } label: {
                Image(systemName: shiftIcon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(shift == .off ? .primary : Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .background(capShape.fill(Color(.tertiarySystemBackground)))
            }
            .buttonStyle(KeyCapStyle())
            .accessibilityLabel("Shift")

        case .backspace:
            BackspaceKey(
                height: keyHeight,
                shape: capShape,
                onPress: onDeletePress,
                onRelease: onDeleteRelease
            )

        case .toLetters:
            specialCap(label: "ABC", flexible: true) { plane = .letters }
        case .toNumbers:
            specialCap(label: "123", flexible: true) { plane = .numbers }
        case .toSymbols:
            specialCap(label: "#+=", flexible: true) { plane = .symbols }
        }
    }

    /// A special (non-character) key. `flexible` shares row width with its
    /// neighbours (used inside the top rows); otherwise a fixed `width` (used
    /// in the bottom row, where space must absorb the remainder).
    @ViewBuilder
    private func specialCap(
        label: String? = nil,
        systemImage: String? = nil,
        width: CGFloat? = nil,
        flexible: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
                } else if let label {
                    Text(label).font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: flexible ? .infinity : nil)
            .frame(width: flexible ? nil : width, height: keyHeight)
            .background(capShape.fill(Color(.tertiarySystemBackground)))
        }
        .buttonStyle(KeyCapStyle())
        .accessibilityLabel(label ?? systemImage ?? "")
    }

    // MARK: - Helpers

    private func cycleShift() {
        switch shift {
        case .off: shift = .oneShot
        case .oneShot: shift = .locked
        case .locked: shift = .off
        }
    }

    private var shiftIcon: String {
        switch shift {
        case .off: return "shift"
        case .oneShot: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    private let keyHeight: CGFloat = 42
    private var capShape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }
}

/// Backspace cap with press / release routed to the controller's hold-to-repeat
/// timer (mirrors the dictation pad's backspace). A zero-duration long-press
/// gesture gives us press-down / lift-up edges; a quick tap still fires one
/// delete because the controller calls `deleteBackward()` on press.
private struct BackspaceKey: View {
    let height: CGFloat
    let shape: RoundedRectangle
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(shape.fill(Color(.tertiarySystemBackground)))
            .opacity(pressed ? 0.6 : 1)
            .contentShape(shape)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                // Tap completion is a no-op; the press edge already deleted.
            } onPressingChanged: { isPressing in
                if isPressing, !pressed {
                    pressed = true
                    onPress()
                } else if !isPressing, pressed {
                    pressed = false
                    onRelease()
                }
            }
            .accessibilityLabel("Backspace")
    }
}

/// Press feedback for keycaps — dims briefly while held, like a real key.
private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
