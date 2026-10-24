import SwiftUI

/// Keyboard mockup used only for App Store screenshots.
///
/// The real Dictator keyboard is an app-extension binary that only
/// shows up inside other apps after the user enables it in Settings →
/// Keyboards. We can't drive that automatically in the iOS Simulator
/// without a long setup dance (provision the extension, switch into
/// Notes, switch keyboards). So this puts a faux compose surface up top
/// and the keyboard's real layout, `KeyboardRootView` (compiled into the
/// app for this, see project.yml), at its real height below — the
/// screenshot can't drift from the keyboard because it is the keyboard.
///
/// Gated behind `DICTATOR_SCREENSHOT_STATE` (or the matching
/// `-DictatorScreenshotState_…` launch argument) so only the screenshot
/// harness ever surfaces it:
/// - `keyboard`: idle, with a Dictator transcript on the clipboard.
/// - `keyboard-recording`: a dictation in progress (the red pill).
/// - `keyboard-assist`: an Assist instruction in progress (the violet pill).
struct KeyboardShowcase: View {
    enum State: String, CaseIterable {
        case idle = "keyboard"
        case recording = "keyboard-recording"
        case assist = "keyboard-assist"
    }

    /// The showcase state the harness asked for, or nil to run the app.
    static var requested: State? {
        if let value = ProcessInfo.processInfo.environment["DICTATOR_SCREENSHOT_STATE"],
           let state = State(rawValue: value) {
            return state
        }
        let arguments = CommandLine.arguments
        return State.allCases.first { arguments.contains("-DictatorScreenshotState_\($0.rawValue)") }
    }

    var state: State = .idle

    var body: some View {
        VStack(spacing: 0) {
            // Faux "Notes" compose area to convey context — the
            // keyboard otherwise floats with no anchor and confuses
            // viewers about where the buttons get used.
            VStack(alignment: .leading, spacing: 8) {
                Text("Mum's birthday")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Saturday 14th — book the table at the new place on Elm, six of us, ask about the garden side.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                Text("|")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            Spacer()
            keyboard
                .frame(height: KeyboardRootView.height)
                .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var keyboard: some View {
        KeyboardRootView(
            onMicPress: {},
            onAssistPress: {},
            session: session,
            levels: Self.levels,
            notice: nil,
            onStop: {},
            onCancel: {},
            onEndSession: {},
            onUndo: {},
            onSpace: {},
            onReturn: {},
            assistSupported: true,
            canAssist: true,
            onBackspacePress: {},
            onBackspaceRelease: {},
            canUndo: false,
            canPaste: true,
            pastePreview: "Pick up flowers on the way home, will swing by the place on Elm.",
            onPaste: {}
        )
    }

    private var session: KeyboardBridge.SessionState? {
        switch state {
        case .idle:
            return nil
        case .recording, .assist:
            return KeyboardBridge.SessionState(
                phase: .recording,
                mode: state == .assist ? .assist : .record,
                serving: nil,
                level: 0.5,
                expiresAt: nil,
                updatedAt: Date()
            )
        }
    }

    /// A plausible stretch of speech for the meter.
    private static let levels: [Float] = (0..<64).map { i in
        let x = Double(i)
        return Float(0.18 + 0.32 * abs(sin(x * 0.7)) * (0.6 + 0.4 * abs(cos(x * 0.23))))
    }
}
