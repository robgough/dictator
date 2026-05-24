import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewModel = RecordingViewModel()
    /// True while the transcript `TextEditor` holds focus (i.e. the
    /// system keyboard is up). Drives the layout collapse — when
    /// editing, the keyboard eats ~half the screen on phones, so the
    /// mic/copy controls compress to a single row.
    @FocusState private var transcriptFocused: Bool
    /// Shows the model-info sheet (status, unload). Driven by a tap
    /// on the persistent model-status chip in `grantedContent`.
    @State private var showingModelSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch viewModel.permission {
                case .undetermined:
                    permissionPrompt
                case .denied:
                    permissionDenied
                case .granted:
                    grantedContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            // Whole-screen tap target with a low-priority tap gesture so
            // any tap outside an actual interactive element (TextEditor,
            // Copy button, mic button) dismisses the keyboard. SwiftUI
            // routes taps to the deepest hit-tested view first, so the
            // buttons / TextEditor keep their normal behaviour; only
            // taps in the gaps between bubble up to here.
            .contentShape(Rectangle())
            .onTapGesture {
                Self.dismissKeyboard()
            }
            .navigationTitle("Dictator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView(viewModel: viewModel)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .task { await viewModel.requestPermissionIfNeeded() }
    }

    /// Resigns first responder app-wide. Cheaper than threading a
    /// `@FocusState` binding through every view that hosts the
    /// `TextEditor`; the system's `resignFirstResponder` action walks
    /// the responder chain and tells whichever field currently has
    /// focus to give it up.
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// One-line tradeoff blurb for the selected Parakeet model. Shown
    /// underneath the segmented picker in `downloadPrompt` so the user
    /// sees the consequence of their choice before kicking off the
    /// ~460 MB download.
    private func modelBlurb(for id: String) -> String {
        switch id {
        case "parakeet-tdt-0.6b-v2":
            "Best for English-only dictation. Tighter English accuracy than v3 because it isn't splitting capacity across other languages."
        case "parakeet-tdt-0.6b-v3":
            "Multilingual — English, German, French, Italian, Spanish, Portuguese, Russian, Ukrainian, and other European languages. Pick this if you dictate in more than one language."
        default:
            ""
        }
    }

    /// Persistent model-status pill at the top of the granted-content
    /// view. Visible whenever the model files are on disk — even when
    /// the model isn't loaded into memory. Three visual states:
    ///   - Loading (prewarm in flight) → spinner + "Loading model…"
    ///   - Loaded                     → green dot + "Model loaded"
    ///   - Ready (on disk, not loaded) → grey dot + "Model ready"
    /// Tapping opens the model sheet (status + unload action).
    private var modelStatusChip: some View {
        Button {
            showingModelSheet = true
        } label: {
            HStack(spacing: 6) {
                if viewModel.isModelLoading {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading model…")
                } else if viewModel.isModelLoaded {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    Text("Model loaded")
                } else {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                    Text("Model ready")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    /// First-launch / post-removal call-to-action. Replaces the entire
    /// recording UI until the user explicitly kicks off a download —
    /// pressing the mic before the model exists would just sit silently,
    /// which is the bug this fixes.
    private var downloadPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Download transcription model")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Dictator needs the Parakeet speech model (~460 MB) on this device before it can transcribe. One-time download.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            // Model picker above the CTA. Selecting a variant the user
            // already has on disk transitions the UI out of the
            // download prompt entirely (handled by selectModel
            // re-evaluating disk status). Picker bound to a derived
            // Binding so the change funnels through the view model
            // rather than mutating a separate @State copy.
            Picker(
                "Model",
                selection: Binding(
                    get: { viewModel.selectedModelID },
                    set: { viewModel.selectModel($0) }
                )
            ) {
                Text("v3 · Multilingual").tag("parakeet-tdt-0.6b-v3")
                Text("v2 · English").tag("parakeet-tdt-0.6b-v2")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Selection-aware blurb explaining the tradeoff. Both
            // models are ~460 MB and similar in raw size; the real
            // difference is multilingual coverage vs tighter English-
            // only accuracy. Surfacing this here keeps users from
            // accidentally downloading v3 when they only ever dictate
            // in English (v2 wins on accuracy in that case).
            Text(modelBlurb(for: viewModel.selectedModelID))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, -8)

            Button {
                Task { await viewModel.downloadModel() }
            } label: {
                Text("Download (~460 MB)")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            Spacer()
        }
    }

    /// Active-download UI. Linear progress bar + percentage + MB
    /// readout so the user knows the app isn't stuck. ~460 MB is the
    /// nominal size for parakeet-tdt-0.6b-v3; close enough for the
    /// "X MB of 460 MB" display even though real bytes vary slightly.
    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Downloading model…")
                .font(.title3.weight(.semibold))
            ProgressView(value: max(0, min(1, progress)))
                .progressViewStyle(.linear)
                .padding(.horizontal)
            Text("\(Int(progress * 100))%  ·  \(Int(progress * 460)) MB of 460 MB")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Keep Dictator open until this finishes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    /// Failure UI. Retry button rewinds to `.notDownloaded` so the CTA
    /// reappears and the user can try again.
    private func downloadFailedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.orange)
            Text("Download failed")
                .font(.title3.weight(.semibold))
            Text(reason)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button {
                viewModel.resetDownload()
            } label: {
                Text("Try again")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            Spacer()
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Dictator needs the microphone to transcribe your voice.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await viewModel.requestPermissionIfNeeded() }
            } label: {
                Text("Allow Microphone Access")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var permissionDenied: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.red)
            Text("Microphone access is off.")
                .font(.headline)
            Text("Open the Settings app and turn on the microphone for Dictator to use this prototype.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder
    private var grantedContent: some View {
        switch viewModel.modelDiskStatus {
        case .notDownloaded, .checking:
            // `.checking` shouldn't linger — the disk check in `init`
            // is synchronous — but cover it as a download-prompt
            // because that's the safer end of the spectrum if we're
            // ever wrong about disk presence.
            downloadPrompt
                .sheet(isPresented: $showingModelSheet) { ModelStatusSheet(viewModel: viewModel) }
        case .downloading(let progress):
            downloadingView(progress: progress)
        case .failed(let reason):
            downloadFailedView(reason: reason)
        case .downloaded:
            recordingArea
        }
    }

    /// The "model is on disk, you can record" layout. Status chip
    /// pinned at the top, then transcript card, then the (focus-aware)
    /// controls.
    private var recordingArea: some View {
        VStack(spacing: 16) {
            HStack {
                modelStatusChip
                Spacer()
            }

            TranscriptCard(
                text: $viewModel.transcript,
                status: viewModel.status,
                focus: $transcriptFocused
            )
            .frame(maxHeight: .infinity)
            // Floating undo button at the bottom-left of the
            // transcript card. Visible only when there's a snapshot
            // to swap to (after a dictation or assist run). Tapping
            // toggles current ↔ previous so it doubles as redo.
            .overlay(alignment: .bottomLeading) {
                if viewModel.canUndo {
                    UndoButton(action: viewModel.undo)
                        .padding(12)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.canUndo)

            if transcriptFocused {
                compactControls
            } else {
                fullControls
            }
        }
        // Both layouts animate in/out together — the mic shrink, the
        // copy-button reshape, and the status-label fade share the
        // same spring so the whole transition reads as one motion
        // rather than three.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: transcriptFocused)
        .sheet(isPresented: $showingModelSheet) {
            ModelStatusSheet(viewModel: viewModel)
        }
    }

    /// Default layout: red mic + purple assist button (when AI is
    /// available) side by side, Copy as a wide bar above, status label
    /// + health warning underneath.
    private var fullControls: some View {
        VStack(spacing: 16) {
            Button {
                viewModel.copyTranscriptToClipboard()
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.transcript.isEmpty)

            HStack(spacing: 28) {
                HoldButton(
                    status: viewModel.status,
                    tint: .red,
                    restingIcon: "mic.fill",
                    isMyTurn: viewModel.recordingMode == .dictation,
                    compact: false,
                    onPress: { viewModel.startRecording() },
                    onRelease: { Task { await viewModel.stopRecording() } }
                )
                .disabled(otherButtonBusy(for: .dictation))
                .opacity(otherButtonBusy(for: .dictation) ? 0.4 : 1)

                if AppleFoundationAssist.isAvailable {
                    HoldButton(
                        status: viewModel.status,
                        tint: .purple,
                        restingIcon: "wand.and.stars",
                        isMyTurn: viewModel.recordingMode == .assist,
                        compact: false,
                        onPress: { viewModel.startAssistRecording() },
                        onRelease: { Task { await viewModel.stopAssistRecording() } }
                    )
                    .disabled(assistDisabled)
                    .opacity(assistDisabled ? 0.35 : 1)
                }
            }

            StatusLabel(status: viewModel.status, mode: viewModel.recordingMode)
                .frame(height: 22)

            healthWarning
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Keyboard-up layout: mic + assist + copy in one row, all compact.
    /// Health warning hidden in this state — vertical space is at a
    /// premium and the warning is already visible whenever the
    /// keyboard isn't up.
    private var compactControls: some View {
        HStack(spacing: 10) {
            HoldButton(
                status: viewModel.status,
                tint: .red,
                restingIcon: "mic.fill",
                isMyTurn: viewModel.recordingMode == .dictation,
                compact: true,
                onPress: {
                    // See full-layout note above — keyboard stays up
                    // during recording on purpose, otherwise the layout
                    // reflows mid-press and SwiftUI loses the gesture.
                    viewModel.startRecording()
                },
                onRelease: { Task { await viewModel.stopRecording() } }
            )
            .disabled(otherButtonBusy(for: .dictation))
            .opacity(otherButtonBusy(for: .dictation) ? 0.4 : 1)

            if AppleFoundationAssist.isAvailable {
                HoldButton(
                    status: viewModel.status,
                    tint: .purple,
                    restingIcon: "wand.and.stars",
                    isMyTurn: viewModel.recordingMode == .assist,
                    compact: true,
                    onPress: { viewModel.startAssistRecording() },
                    onRelease: { Task { await viewModel.stopAssistRecording() } }
                )
                .disabled(assistDisabled)
                .opacity(assistDisabled ? 0.35 : 1)
            }

            Button {
                viewModel.copyTranscriptToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.transcript.isEmpty)
        }
        .transition(.opacity)
    }

    /// Subtle footer reminding the user that on-device AI cleanup +
    /// assist output is best-effort. Sits below the status label in
    /// the full layout; deliberately quiet (caption2, tertiary) so it
    /// reads as a footnote, not a chyron.
    private var healthWarning: some View {
        Text("The on-device assistant runs locally and can make mistakes. Always read the result back before relying on it.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// True when the assist (purple) button should be disabled —
    /// either Apple Intelligence isn't on, there's no transcript to
    /// transform, or the dictation flow is currently busy.
    private var assistDisabled: Bool {
        !AppleFoundationAssist.isAvailable
            || viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || otherButtonBusy(for: .assist)
    }

    /// `true` when the OTHER recording mode is currently in flight, so
    /// this button shouldn't accept a press. Prevents starting an
    /// assist while a dictation is mid-transcribe and vice versa.
    private func otherButtonBusy(for mine: RecordingViewModel.RecordingMode) -> Bool {
        guard viewModel.status.isCapturing
                || { if case .transcribing = viewModel.status { return true } else { return false } }()
        else { return false }
        return viewModel.recordingMode != mine
    }
}

// MARK: - Transcript card

private struct TranscriptCard: View {
    @Binding var text: String
    let status: RecordingViewModel.Status
    /// Pass-through `@FocusState.Binding` so the parent view can react
    /// to the TextEditor gaining/losing focus. SwiftUI's `@FocusState`
    /// is scoped to its declaring view, hence the `Binding` plumbing.
    @FocusState.Binding var focus: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            // TextEditor for editability — the prototype lets the user
            // tweak the transcribed text before copying. Background is
            // .clear so the rounded card shows through.
            TextEditor(text: $text)
                .focused($focus)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .padding(12)
                .font(.body)

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(20)
                    .allowsHitTesting(false)
            }
        }
    }

    private var placeholder: String {
        switch status {
        case .transcribing: "Working on it…"
        case .error(let message): message
        default: "Hold the mic button and start talking. Release to transcribe."
        }
    }
}

// MARK: - Undo button

/// Small floating undo button overlaid on the bottom-left of the
/// transcript card. `.thinMaterial` background so it reads cleanly
/// over the transcript text, which can scroll behind it.
private struct UndoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo")
    }
}

// MARK: - Hold-to-talk button

/// Round press-and-hold button shared between the red mic (records
/// dictation) and the purple assist wand (records an instruction to
/// apply to the current transcript). Same gesture shape, different
/// tint + icon + action.
///
/// `isMyTurn` is set by the parent based on `viewModel.recordingMode`
/// — it lets the active button show the level-driven outer ring while
/// the other button stays still. The active button also swaps its
/// icon to "hourglass" during the transcribing/transforming stage so
/// the user knows which button's flow is in progress.
private struct HoldButton: View {
    let status: RecordingViewModel.Status
    let tint: Color
    let restingIcon: String
    let isMyTurn: Bool
    let compact: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    private var diameter: CGFloat { compact ? 52 : 96 }

    /// Level-driven ring only shown around the button whose press is
    /// currently driving the recording. Without the `isMyTurn` gate
    /// both buttons would pulse on every dictation.
    private var level: Float {
        if isMyTurn, case let .recording(level) = status { return level }
        return 0
    }

    private var displayedIcon: String {
        if isMyTurn, case .transcribing = status {
            return "hourglass"
        }
        return restingIcon
    }

    var body: some View {
        let ringMax: CGFloat = compact ? 14 : 60
        let iconSize: CGFloat = compact ? 22 : 36
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(
                    width: diameter + CGFloat(level) * ringMax,
                    height: diameter + CGFloat(level) * ringMax
                )
                .animation(.easeOut(duration: 0.08), value: level)

            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
                .overlay(
                    Image(systemName: displayedIcon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .scaleEffect(isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
                .contentShape(Circle())
        }
        .frame(
            width: diameter + (compact ? 8 : 20),
            height: diameter + 12,
            alignment: .center
        )
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
            // Tap-completion — unused; press/release fire via
            // onPressingChanged so the recorder mirrors the touch.
        } onPressingChanged: { pressing in
            if pressing, !isPressed {
                isPressed = true
                onPress()
            } else if !pressing, isPressed {
                isPressed = false
                onRelease()
            }
        }
    }
}

// MARK: - Status label

private struct StatusLabel: View {
    let status: RecordingViewModel.Status
    let mode: RecordingViewModel.RecordingMode

    var body: some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView()
                    .scaleEffect(0.8)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var text: String {
        switch status {
        case .idle: "Hold to talk"
        case .warmingUp: "Warming up…"
        case .recording:
            mode == .assist
                ? "Listening — release to apply the instruction"
                : "Listening — release to transcribe"
        case .transcribing:
            mode == .assist ? "Applying…" : "Transcribing…"
        // No prompt in the ready state — the transcript itself is the
        // result, and the buttons read clearly without a caption.
        case .ready: ""
        case .error: "Something went wrong"
        }
    }

    private var showsSpinner: Bool {
        switch status {
        case .transcribing: true
        default: false
        }
    }
}

#Preview {
    ContentView()
}
