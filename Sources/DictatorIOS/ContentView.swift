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

    /// Default layout: big circular mic centred, copy as a wide bar
    /// above it, status label underneath.
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

            MicButton(status: viewModel.status, compact: false) {
                viewModel.startRecording()
            } onRelease: {
                Task { await viewModel.stopRecording() }
            }

            StatusLabel(status: viewModel.status)
                .frame(height: 22)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Keyboard-up layout: mic shrinks to a small circle on the left,
    /// copy collapses to a square button on the right. Both share the
    /// available row width so the controls stay reachable just above
    /// the keyboard.
    private var compactControls: some View {
        HStack(spacing: 12) {
            MicButton(status: viewModel.status, compact: true) {
                // Deliberately NOT dismissing the keyboard here —
                // doing so on press triggers the layout transition
                // mid-touch, the mic button's frame reflows, and
                // SwiftUI's gesture system loses the press,
                // immediately firing `onRelease` and aborting the
                // recording. The compact layout is designed for
                // keyboard-up use; recording works fine in place.
                // The user can dismiss the keyboard manually
                // (tap outside / swipe the transcript) when ready.
                viewModel.startRecording()
            } onRelease: {
                Task { await viewModel.stopRecording() }
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

// MARK: - Mic button

private struct MicButton: View {
    let status: RecordingViewModel.Status
    /// When true, render at a smaller size suitable for sitting on the
    /// same row as the Copy button while the keyboard is up.
    let compact: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isPressed = false

    private var diameter: CGFloat { compact ? 52 : 96 }

    /// Level-driven outer glow. When the user is actively recording the
    /// button gets a faint, pulsing ring proportional to mic input — gives
    /// the prototype the same "yes, I'm hearing you" feedback the macOS
    /// HUD provides via its waveform.
    private var level: Float {
        if case let .recording(level) = status { return level }
        return 0
    }

    var body: some View {
        // Compact ring growth is tight — the button shares its row
        // with the Copy button so a large `ringMax` (matching the
        // full-layout 80) would visually bleed into it at peak
        // volume.
        let ringMax: CGFloat = compact ? 14 : 80
        let iconSize: CGFloat = compact ? 22 : 36
        ZStack {
            Circle()
                .fill(.tint.opacity(0.18))
                .frame(
                    width: diameter + CGFloat(level) * ringMax,
                    height: diameter + CGFloat(level) * ringMax
                )
                .animation(.easeOut(duration: 0.08), value: level)

            Circle()
                .fill(buttonFill)
                .frame(width: diameter, height: diameter)
                .overlay(
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .scaleEffect(isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
                .contentShape(Circle())
        }
        // In compact mode the button shares its row with the Copy
        // button — drop the wide horizontal padding ring so the
        // level-glow doesn't bleed into the Copy button.
        .frame(
            width: compact ? diameter + 8 : diameter + 80,
            height: diameter + 12,
            alignment: .center
        )
        // onLongPressGesture with minimumDuration: 0 is the SwiftUI idiom
        // for press-and-hold: onPressingChanged fires immediately on touch
        // down and again on touch up. DragGesture works too but adds drift
        // semantics we don't need here.
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
            // Tap-completion handler — fires after release. Unused; press
            // and release are wired through onPressingChanged so the
            // recorder mirrors the physical press.
        } onPressingChanged: { pressing in
            if pressing, !isPressed {
                isPressed = true
                onPress()
            } else if !pressing, isPressed {
                isPressed = false
                onRelease()
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private var iconName: String {
        switch status {
        case .transcribing: "hourglass"
        default: "mic.fill"
        }
    }

    private var buttonFill: Color {
        switch status {
        case .recording, .warmingUp: .red
        default: .accentColor
        }
    }

    private var disabled: Bool {
        switch status {
        case .transcribing: true
        default: false
        }
    }
}

// MARK: - Status label

private struct StatusLabel: View {
    let status: RecordingViewModel.Status

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
        case .recording: "Listening — release to transcribe"
        case .transcribing: "Transcribing…"
        // No prompt in the ready state — the transcript itself is the
        // result, and the mic + copy buttons read clearly without a
        // caption. Keeps the layout from feeling instruction-heavy.
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
