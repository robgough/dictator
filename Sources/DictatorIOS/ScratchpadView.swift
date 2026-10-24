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
    /// Opens Settings: the top-bar gear, and connecting a shared folder.
    var onOpenSettings: () -> Void

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
            // Every control at the bottom — mic, Reword, space, return,
            // delete — is one row in the TabView's bottom accessory (see
            // `ScratchpadControlsAccessory`), so it docks beside the tab bar
            // when that shrinks on scroll and nothing floats over the note.
            .navigationTitle("Scratchpad")
            .navigationBarTitleDisplayMode(.inline)
            // Only the hold-to-talk buttons float at the bottom; everything
            // else is a top-bar action, per the Liquid Glass layout. Undo and
            // the keyboard are different kinds of action, so separate capsules.
            .toolbar {
                if model.canUndo && !recordingInProgress {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.undo()
                        } label: {
                            Image(systemName: model.didUndo ? "arrow.uturn.forward" : "arrow.uturn.backward")
                        }
                        .accessibilityLabel(model.didUndo ? "Redo" : "Undo")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        keyboardEnabled.toggle()
                    } label: {
                        Image(systemName: keyboardEnabled ? "keyboard.chevron.compact.down" : "keyboard")
                    }
                    .accessibilityLabel(keyboardEnabled ? "Hide keyboard" : "Show keyboard")
                    .disabled(recordingInProgress)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(action: onOpenSettings)
                }
            }
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
            // The mic and Reword live in the accessory; starting either puts
            // the keyboard away, as pressing them always has.
            .onChange(of: recordingInProgress) { _, recording in
                if recording { keyboardEnabled = false }
            }
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
        .readableWidth(760)
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
                Button(action: onOpenSettings) {
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
}

// MARK: - Controls accessory

/// Every Scratchpad control in one row of the TabView's bottom accessory
/// (`tabViewBottomAccessory`): mic and Reword on the left, then space, return
/// and delete — the Dictator keyboard's bottom row. The accessory provides
/// the glass bar; these are plain keys on top of it. Keys insert at / delete
/// from the note's caret.
///
/// While one of the two records, it takes the whole row for its listening
/// bars and the rest step aside. When the placement is `.inline` (the tab
/// bar has minimized on scroll) the row compacts beside the shrunken tab
/// button, so it all moves together.
struct ScratchpadControlsAccessory: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var model = ScratchpadModel.shared
    @State private var blocker: MicBlocker?

    private var isInline: Bool { placement == .inline }
    private var keyHeight: CGFloat { isInline ? 32 : 40 }

    private var isScratchpadMode: Bool {
        viewModel.recordingMode == .scratchpad || viewModel.recordingMode == .scratchpadAssist
    }
    private var recordingInProgress: Bool {
        guard isScratchpadMode else { return false }
        if viewModel.status.isCapturing { return true }
        if case .transcribing = viewModel.status { return true }
        return false
    }
    private var micShown: Bool { !recordingInProgress || viewModel.recordingMode == .scratchpad }
    private var assistShown: Bool {
        AppleFoundationAssist.isAvailable
            && (!recordingInProgress || viewModel.recordingMode == .scratchpadAssist)
    }
    private var noteIsEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cursor-aware mic glyph, mirroring the Dictation page: plain mic on an
    /// empty note, "replace" badge when there's a selection, "append" badge
    /// otherwise.
    private var micIcon: String {
        if model.text.isEmpty { return "microphone.fill" }
        if (model.selection?.length ?? 0) > 0 { return "microphone.badge.ellipsis.fill" }
        return "microphone.badge.plus.fill"
    }

    var body: some View {
        HStack(spacing: isInline ? 2 : 4) {
            // Same view identity throughout a recording — swapping the view
            // under a held finger would lose the release.
            if micShown {
                RecordKey(
                    tint: .red, icon: micIcon, label: "Dictate into note",
                    mode: .scratchpad, viewModel: viewModel, height: keyHeight,
                    onPress: { viewModel.startScratchpadRecording() },
                    onRelease: { Task { await viewModel.stopScratchpadRecording() } },
                    onBlocked: { handleBlockedMic(viewModel, showing: $blocker) }
                )
            }
            if assistShown {
                RecordKey(
                    tint: .purple, icon: "wand.and.stars", label: "Reword note",
                    mode: .scratchpadAssist, viewModel: viewModel, height: keyHeight,
                    busyLabel: "Rewording…",
                    enabled: !noteIsEmpty,
                    onPress: { viewModel.startScratchpadAssist() },
                    onRelease: { Task { await viewModel.stopScratchpadAssist() } },
                    onBlocked: { handleBlockedMic(viewModel, showing: $blocker) }
                )
            }
            if !recordingInProgress {
                Divider()
                    .frame(height: isInline ? 18 : 24)
                    .padding(.horizontal, 2)

                Button { edit { $0.insertText(" ") } } label: {
                    Text("space")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: keyHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button { edit { $0.insertText("\n") } } label: {
                    Image(systemName: "return")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: isInline ? 36 : 44, height: keyHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return")

                Button { edit { $0.deleteBackward() } } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: isInline ? 36 : 44, height: keyHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete backward")
            }
        }
        .padding(.horizontal, isInline ? 4 : 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: recordingInProgress)
        .micBlockerAlert($blocker, viewModel: viewModel)
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

/// Glassy, tinted dictation/assist button (the journal entry sheet). Idle, it's a 64pt
/// glass circle with an icon; while it's the active recorder it expands in place
/// (leading edge fixed) into a pill containing the live listening bars — the
/// "listening" animation happens *inside* the button rather than as a separate
/// element, so nothing jumps. Same tap-vs-hold gesture as the Dictation page's
/// `HoldButton`: a quick tap latches recording on (tap again to stop); a longer
/// hold is push-to-talk (release stops).
struct ScratchpadRecordButton: View {
    let tint: Color
    let restingIcon: String
    let status: RecordingViewModel.Status
    let isMyTurn: Bool
    let recordingStartCount: Int
    let onPress: () -> Void
    let onRelease: () -> Void
    /// Can't record yet (no permission, no model). The button stays live so
    /// a press can explain why, via `onBlocked`, instead of a caption sitting
    /// beside it all the time.
    var blocked = false
    var onBlocked: () -> Void = {}
    /// Tapped while transcribing or rewording.
    var onCancel: () -> Void = {}

    @State private var isPressed = false
    @State private var isLatched = false
    @State private var pressStartedAt: Date?
    /// Reflects `.disabled()`. We fade the icon (not the glass — `.opacity`
    /// doesn't affect glassEffect) to signal the disabled / no-model state.
    @Environment(\.isEnabled) private var isEnabled

    private static let holdThreshold: TimeInterval = 0.35
    /// The mic is the reason the app exists, so it's the biggest control on
    /// the screen — bigger than the 44pt toolbar buttons above.
    static let size: CGFloat = 64
    private var height: CGFloat { Self.size }
    private let expandedWidth: CGFloat = 210

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
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint.opacity(isEnabled && !blocked ? 1 : 0.3))
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
            // While its words are being worked on, a tap cancels.
            if isTranscribing {
                if pressing { onCancel() }
                return
            }
            if blocked {
                if pressing { onBlocked() }
                isPressed = false
                return
            }
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
