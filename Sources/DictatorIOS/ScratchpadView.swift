import SwiftUI
import UIKit

/// The iOS Scratchpad tab: a plain-text note that syncs with the Mac's
/// Scratchpad (both read/write `scratchpad.md` in the shared folder), with
/// dictation + assist controls that mirror the Dictation page.
///
/// The note's text/selection + autosave live in the shared `ScratchpadModel`
/// (DictatorCore). The mic and assist reuse the Dictation tab's
/// `RecordingViewModel` — same engine, same model prewarm — routed at the
/// note via `stopScratchpadRecording` / `stopScratchpadAssist`:
///   - Mic (red): dictate, merged at the caret / selection (or appended) via
///     the shared `TranscriptMerge`.
///   - Assist (purple): a spoken instruction transforms the selected text, or
///     the whole note when nothing is selected.
///   - Keyboard button: brings up the system keyboard for manual typing; the
///     editor is selection-only otherwise (so taps position the cursor / select
///     without summoning Dictator's own keyboard).
/// While recording, the inactive buttons hide so only the active one + the live
/// waveform remain.
struct ScratchpadView: View {
    /// Shared with the Dictation tab so only one recording runs at a time and
    /// the model prewarm/readiness is reused.
    @Bindable var viewModel: RecordingViewModel
    /// Jump to the Settings tab so the user can connect a shared folder.
    var onConnectFolder: () -> Void

    @State private var model = ScratchpadModel.shared
    /// Mirrors `SharedFolderBookmark.isConfigured`. Re-read on appear so the
    /// sync hint disappears as soon as the user connects a folder in Settings
    /// and returns — the bookmark itself isn't observable.
    @State private var hasSharedFolder = SharedFolderBookmark.isConfigured
    /// Permanent dismissal of the sync hint via its X button.
    @AppStorage(DictatorIOSSettings.scratchpadSyncHintDismissedKey) private var syncHintDismissed = false
    /// Drives the system keyboard (and editor editability) via
    /// `EditableTranscript`. Off by default: tapping the editor positions the
    /// cursor / selects without raising the keyboard. The keyboard button
    /// flips it on; the editor's "Done" accessory flips it back off.
    @State private var keyboardEnabled = false
    /// First-responder mirror from the editor (unused for focus styling here,
    /// but `EditableTranscript` requires the binding).
    @State private var editorFocused = false
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var glass

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                editor

                if model.text.isEmpty {
                    Text("Jot a note — it syncs with your Mac. Tap a button below to dictate, reword, or type.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            // Controls live in a bottom bar, NOT an overlay over the editor:
            // the editor is a UITextView whose gesture recognizers swallow
            // taps on SwiftUI views layered over it. A safeAreaInset insets
            // the editor above the bar (taps land) and the bar rises above the
            // keyboard when it appears (so the keyboard toggle stays reachable).
            // Quick edit keys (space / return / delete) live in the TabView's
            // bottom accessory (see ContentView) so they can dock with the
            // minimized tab bar; only the record / undo / keyboard controls
            // sit here. `safeAreaBar` (not `safeAreaInset`) so the note scrolls
            // UNDER the controls with the iOS 26 progressive scroll-edge blur,
            // instead of a hard cut-off — while still reserving their height so
            // the last line stays reachable above them.
            .safeAreaBar(edge: .bottom) { bottomBar }
            .navigationTitle("Scratchpad")
            .navigationBarTitleDisplayMode(.inline)
            // Match the bottom: content scrolls under the sync hint with the
            // scroll-edge blur, rather than stopping at a hard edge below it.
            .safeAreaBar(edge: .top) { syncHint }
            .onAppear {
                model.reload()
                hasSharedFolder = SharedFolderBookmark.isConfigured
            }
            .onChange(of: scenePhase) { _, phase in
                // Pick up Mac edits on foreground; flush ours on background.
                if phase == .active {
                    model.reload()
                } else if phase == .background {
                    model.saveNow()
                }
            }
            .onDisappear { model.saveNow() }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        // UIKit-backed so drag-select / cursor positioning work and the
        // mic/assist can read the live selection. `caretVisibleWithoutKeyboard`
        // keeps a blinking caret visible and tappable without raising the
        // keyboard — so you can see / place where dictation will land. The
        // keyboard button raises the system keyboard on demand.
        EditableTranscript(
            text: editorTextBinding,
            selection: editorSelectionBinding,
            isFocused: $editorFocused,
            keyboardEnabled: $keyboardEnabled,
            caretVisibleWithoutKeyboard: true,
            // Generous bottom padding inside the text so the note scrolls UNDER
            // the controls (the editor extends under them, below) and the last
            // line still clears them with room to select / edit it.
            bottomTextInset: 220
        )
        .padding(.horizontal, 8)
        // Extend the editor under the bottom controls / tab bar so its content
        // scrolls under them (Liquid Glass), rather than the frame stopping at a
        // hard edge above the bar.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// Writes flow through the model so each keystroke schedules a debounced
    /// save, mirroring the macOS editor's binding.
    private var editorTextBinding: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.text = $0; model.scheduleSave() }
        )
    }

    private var editorSelectionBinding: Binding<NSRange?> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
    }

    // MARK: - Sync hint

    @ViewBuilder
    private var syncHint: some View {
        if !hasSharedFolder && !syncHintDismissed {
            // The connect-card and the dismiss X are SIBLING buttons, not
            // nested — a Button inside another Button's label doesn't get its
            // own tap on iOS, so the X lives outside the card's tappable area.
            HStack(spacing: 8) {
                Button(action: onConnectFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Not syncing with your Mac")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Connect a shared folder in Settings")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Permanent dismissal — closes the hint for good.
                Button {
                    syncHintDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss sync notice")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // Recording controls (mic + assist), bottom-leading. While
                // recording, the inactive button is replaced by a clear
                // placeholder of the same size (not hidden via opacity —
                // `.opacity` doesn't affect glassEffect views) so the active
                // button keeps its exact position and expands in place into a
                // pill with the listening bars inside.
                if !keyboardEnabled {
                    micSlot
                    if assistAvailable { assistSlot }
                }

                Spacer(minLength: 8)

                if let reason = micDisabledReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: 170, alignment: .trailing)
                }

                // Trailing controls: undo/redo (when there's something) +
                // keyboard, on the right-hand side. Hidden while recording.
                // The same button flips to "redo" after an undo.
                if !recordingInProgress {
                    if model.canUndo {
                        circleButton(
                            systemImage: model.didUndo ? "arrow.uturn.forward" : "arrow.uturn.backward",
                            label: model.didUndo ? "Redo" : "Undo"
                        ) {
                            model.undo()
                        }
                    }
                    circleButton(
                        systemImage: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard",
                        label: keyboardEnabled ? "Hide keyboard" : "Show keyboard"
                    ) {
                        keyboardEnabled.toggle()
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: recordingInProgress)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: keyboardEnabled)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.canUndo)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// Red dictation mic. Glassy, like the other controls; expands in place into
    /// a pill with the listening bars when it's the active recorder, and fades
    /// (without moving) when assist is recording.
    private var micButton: some View {
        ScratchpadRecordButton(
            tint: .red,
            restingIcon: micRestingIcon,
            status: viewModel.status,
            isMyTurn: viewModel.recordingMode == .scratchpad,
            recordingStartCount: viewModel.recordingStartCount,
            onPress: { startMic() },
            onRelease: { Task { await viewModel.stopScratchpadRecording() } }
        )
        .id("scratchpad-mic")
        .disabled(micDisabled)
    }

    /// Mic in its slot, or a same-size clear placeholder when it's hidden
    /// during an assist recording (keeps the assist button's position fixed).
    @ViewBuilder private var micSlot: some View {
        if micShown { micButton }
        else { Color.clear.frame(width: 52, height: 52) }
    }

    @ViewBuilder private var assistSlot: some View {
        if assistShown { assistButton }
        else { Color.clear.frame(width: 52, height: 52) }
    }

    /// Purple assist button (spoken instruction transforms the note).
    private var assistButton: some View {
        ScratchpadRecordButton(
            tint: .purple,
            restingIcon: "wand.and.stars",
            status: viewModel.status,
            isMyTurn: viewModel.recordingMode == .scratchpadAssist,
            recordingStartCount: viewModel.recordingStartCount,
            onPress: { startAssist() },
            onRelease: { Task { await viewModel.stopScratchpadAssist() } }
        )
        .id("scratchpad-assist")
        .disabled(assistDisabled)
    }

    /// 52pt glass circle matching the mic/assist size — used for undo and the
    /// keyboard toggle.
    private func circleButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Actions

    private func startMic() {
        keyboardEnabled = false
        viewModel.startScratchpadRecording()
    }

    private func startAssist() {
        keyboardEnabled = false
        viewModel.startScratchpadAssist()
    }

    // MARK: - Derived state

    /// True while a scratchpad-owned capture is live (either mode). Gated on
    /// `recordingMode` so a recording owned by the Dictation tab can't light up
    /// these controls.
    private var isCapturing: Bool {
        isScratchpadMode && viewModel.status.isCapturing
    }

    private var isTranscribingScratch: Bool {
        guard isScratchpadMode else { return false }
        if case .transcribing = viewModel.status { return true }
        return false
    }

    /// True from the moment a scratchpad capture starts until its transcription
    /// finishes — the window where only the active button should show.
    private var recordingInProgress: Bool { isCapturing || isTranscribingScratch }

    private var isScratchpadMode: Bool {
        viewModel.recordingMode == .scratchpad || viewModel.recordingMode == .scratchpadAssist
    }

    /// Each button shows when idle (and not typing) or when it's the active
    /// recorder; during the OTHER button's recording it's swapped for a clear
    /// placeholder so the active button's position never shifts.
    private var micShown: Bool {
        if recordingInProgress { return viewModel.recordingMode == .scratchpad }
        return true
    }
    private var assistShown: Bool {
        if recordingInProgress { return viewModel.recordingMode == .scratchpadAssist }
        return true
    }

    /// Speech ready = mic permission granted AND the model is on disk.
    private var baseReady: Bool {
        guard viewModel.permission == .granted else { return false }
        if case .downloaded = viewModel.modelDiskStatus { return true }
        return false
    }

    private var assistAvailable: Bool { AppleFoundationAssist.isAvailable }

    private var noteIsEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var micDisabled: Bool { !baseReady }

    private var assistDisabled: Bool { !baseReady || noteIsEmpty }

    /// Cursor-aware mic glyph, mirroring the Dictation page: plain mic on an
    /// empty note, "replace" badge when there's a selection, "append" badge
    /// otherwise.
    private var micRestingIcon: String {
        if model.text.isEmpty { return "microphone.fill" }
        if (model.selection?.length ?? 0) > 0 { return "microphone.badge.ellipsis.fill" }
        return "microphone.badge.plus.fill"
    }

    /// Why the controls can't dictate, shown as a small caption. nil when
    /// ready (or already mid-capture/transcribe, where the caption is noise).
    private var micDisabledReason: String? {
        if recordingInProgress { return nil }
        if viewModel.permission != .granted {
            return "Allow microphone access to dictate."
        }
        if case .downloaded = viewModel.modelDiskStatus {} else {
            return "Download the speech model on the Dictation tab to dictate."
        }
        return nil
    }
}

// MARK: - Quick keys accessory

/// Space / return / delete keys for the Scratchpad, rendered inside the
/// TabView's bottom accessory (`tabViewBottomAccessory`). The accessory itself
/// provides the glass bar; these are plain keys on top of it. Space is wide
/// (like a spacebar); return and delete sit on the right — matching the Dictator
/// keyboard's bottom row. They insert at / delete from the note's caret.
///
/// When the placement is `.inline` (the tab bar has minimized on scroll), the
/// keys compact so they fit beside the shrunken tab button.
struct ScratchpadQuickKeysAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: 6) {
            Button { edit { $0.insertText(" ") } } label: {
                Text("space")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: isInline ? 32 : 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button { edit { $0.insertText("\n") } } label: {
                Image(systemName: "return")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: isInline ? 32 : 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Return")

            Button { edit { $0.deleteBackward() } } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: isInline ? 32 : 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete backward")
        }
        .padding(.horizontal, 8)
    }

    /// Run an edit on the live editor at its real caret (like a keyboard key) —
    /// no model-selection round-trip. Suppresses the editor's scroll-to-caret
    /// and pins the offset so the view doesn't jump (the edit lands at the
    /// caret; the user's scroll position is preserved).
    private func edit(_ action: (UITextView) -> Void) {
        guard let tv = ScratchpadEditor.activeTextView else { return }
        let offset = tv.contentOffset
        tv.suppressAutoScroll = true
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
        action(tv)
        tv.setContentOffset(offset, animated: false)
        DispatchQueue.main.async { tv.suppressAutoScroll = false }
    }
}

// MARK: - Scratchpad record button

/// Glassy, tinted dictation/assist button for the Scratchpad. Idle, it's a 52pt
/// glass circle with an icon; while it's the active recorder it expands in place
/// (leading edge fixed) into a pill containing the live listening bars — the
/// "listening" animation happens *inside* the button rather than as a separate
/// element, so nothing jumps. Same tap-vs-hold gesture as the Dictation page's
/// `HoldButton`: a quick tap latches recording on (tap again to stop); a longer
/// hold is push-to-talk (release stops).
private struct ScratchpadRecordButton: View {
    let tint: Color
    let restingIcon: String
    let status: RecordingViewModel.Status
    let isMyTurn: Bool
    let recordingStartCount: Int
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false
    @State private var isLatched = false
    @State private var pressStartedAt: Date?
    /// Reflects `.disabled()`. We fade the icon (not the glass — `.opacity`
    /// doesn't affect glassEffect) to signal the disabled / no-model state.
    @Environment(\.isEnabled) private var isEnabled

    private static let holdThreshold: TimeInterval = 0.35
    private let height: CGFloat = 52
    private let expandedWidth: CGFloat = 184

    private var isCapturing: Bool { isMyTurn && status.isCapturing }
    private var isTranscribing: Bool {
        if isMyTurn, case .transcribing = status { return true }
        return false
    }
    private var level: Float {
        if isMyTurn, case let .recording(l) = status { return l }
        return 0
    }

    var body: some View {
        ZStack {
            if isCapturing {
                HStack(spacing: 10) {
                    Waveform(level: level, tint: tint, height: 22)
                        .id(recordingStartCount)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 18)
                .transition(.opacity)
            } else if isTranscribing {
                ProgressView().tint(tint)
            } else {
                Image(systemName: restingIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.3))
                    .transition(.opacity)
            }
        }
        .frame(width: isCapturing ? expandedWidth : height, height: height)
        // Neutral glass — same as the undo / keyboard buttons — so it doesn't
        // look out of place. The red / purple identity comes from the tinted
        // icon and listening bars, not a solid fill.
        .glassEffect(.regular, in: .capsule)
        .scaleEffect(isPressed ? 0.96 : 1)
        .contentShape(.capsule)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: isCapturing)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        // Tap-vs-hold resolved on release, matching HoldButton.
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
        } onPressingChanged: { pressing in
            if pressing, !isPressed {
                isPressed = true
                if !isLatched {
                    pressStartedAt = Date()
                    onPress()
                }
            } else if !pressing, isPressed {
                isPressed = false
                if isLatched {
                    isLatched = false
                    onRelease()
                } else {
                    let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressStartedAt = nil
                    if elapsed >= Self.holdThreshold {
                        onRelease()
                    } else {
                        isLatched = true
                    }
                }
            }
        }
        .onChange(of: isMyTurn) { _, mine in if !mine { isLatched = false } }
        .onChange(of: statusKey) { _, _ in
            // Clear a stale latch if the recorder finished for any other reason.
            if !status.isCapturing, !isTranscribingAny { isLatched = false }
        }
        .accessibilityLabel(restingIcon == "wand.and.stars" ? "Reword note" : "Dictate into note")
    }

    private var isTranscribingAny: Bool {
        if case .transcribing = status { return true }
        return false
    }

    /// Coarse status identifier so `.onChange` fires on phase changes, not on
    /// every level update inside `.recording(level:)`.
    private var statusKey: String {
        switch status {
        case .idle: "idle"
        case .warmingUp: "warmingUp"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .ready: "ready"
        case .error: "error"
        }
    }
}
