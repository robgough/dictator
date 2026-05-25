import SwiftUI
import UIKit

struct ContentView: View {
    /// Optional keyboard-extension hand-off. When non-nil, the
    /// granted-content view shows a "Keyboard mode" banner and the
    /// view model will write the next successful transcript to the
    /// shared App Group container for the keyboard to insert.
    @Binding var keyboardRequest: KeyboardBridge.Request?

    @State private var viewModel = RecordingViewModel()
    /// True while the transcript `TextEditor` holds focus (i.e. the
    /// system keyboard is up). Drives the layout collapse — when
    /// editing, the keyboard eats ~half the screen on phones, so the
    /// mic/copy controls compress to a single row.
    @FocusState private var transcriptFocused: Bool
    /// Mirrored to the bridge so the keyboard extension can both
    /// self-dismiss inside the Dictator app and freshness-check the
    /// model readiness chip (we only trust `loaded` while the host
    /// is actively heartbeating; a backgrounded or killed host ages
    /// out of the "ready" state).
    @Environment(\.scenePhase) private var scenePhase
    /// Shows the model-info sheet (status, unload). Driven by a tap
    /// on the persistent model-status chip in `grantedContent`.
    @State private var showingModelSheet = false
    /// Shows the "return to your app" hint alert in keyboard mode.
    @State private var showingReturnHint = false
    /// Shows the keyboard-setup walkthrough sheet from the onboarding
    /// card on the main view.
    @State private var showingKeyboardSetup = false
    /// Persistent dismissal of the onboarding card. Flips to true
    /// once the user either taps the card's X or — handled in the
    /// onChange handler — actually uses the keyboard.
    @AppStorage(DictatorIOSSettings.keyboardOnboardingDismissedKey) private var keyboardOnboardingDismissed = false
    /// Drives the unified first-launch sheet. Flipped to true when
    /// the user either walks through every step (auto-dismisses on
    /// step 4 completion) or taps "Skip for now". Supersedes the
    /// older keyboard-card flag — the existing scattered cards stay
    /// around as fallback re-prompts, but the sheet is one-and-done.
    @AppStorage(DictatorIOSSettings.onboardingCompletedKey) private var onboardingCompleted = false

    /// Default initialiser for non-keyboard use — wraps a non-bound
    /// constant nil so existing call sites keep working.
    init(keyboardRequest: Binding<KeyboardBridge.Request?> = .constant(nil)) {
        self._keyboardRequest = keyboardRequest
    }

    var body: some View {
        // Screenshot-capture hook. Replaces the entire UI with the
        // standalone keyboard mockup when the harness asks for it —
        // the real Dictator keyboard is an app extension that only
        // shows in a host app after Settings setup, which we can't
        // drive automatically in the simulator.
        if ProcessInfo.processInfo.environment["DICTATOR_SCREENSHOT_STATE"] == "keyboard"
            || CommandLine.arguments.contains("-DictatorScreenshotState_keyboard") {
            return AnyView(KeyboardShowcase())
        }
        return AnyView(mainContent)
    }

    private var mainContent: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if keyboardRequest != nil {
                    keyboardModeBanner
                }
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
            .onChange(of: keyboardRequest, initial: true) { _, new in
                // Cold-launch and warm-launch both flow through here.
                // Hand the active session to the view model so the
                // next successful transcript writes back to the
                // App Group container.
                viewModel.activeKeyboardSession = new?.session
                // First successful arrival from the keyboard means
                // the user has clearly enabled it — hide the
                // onboarding card from now on without them having to
                // tap dismiss.
                if new != nil {
                    keyboardOnboardingDismissed = true
                }
                // Auto-start the appropriate flow when arriving via
                // the keyboard. The user already pressed the
                // corresponding tile in the keyboard — making them
                // tap again once the host opens would feel broken.
                if let req = new, viewModel.permission == .granted {
                    switch req.mode {
                    case .record:
                        viewModel.startRecording()
                    case .assist:
                        // Pre-populate the transcript with the field
                        // contents the keyboard captured, then start
                        // recording the instruction the user is
                        // about to speak.
                        viewModel.transcript = req.surroundingText ?? ""
                        viewModel.startAssistRecording()
                    }
                }
            }
            .onChange(of: viewModel.activeKeyboardSession) { _, current in
                // View model cleared the session after writing the
                // result — clear the binding too so the banner
                // disappears and a subsequent dictation behaves as
                // a regular in-app one.
                if current == nil { keyboardRequest = nil }
            }
            .onChange(of: scenePhase, initial: true) { _, new in
                // Drives two pieces of state at once:
                //   1. The keyboard's auto-dismiss check (don't summon
                //      the Dictator keyboard inside the Dictator app).
                //   2. The keyboard's model-readiness freshness gate —
                //      the view model heartbeats readiness while
                //      foregrounded so a stale `loaded: true` claim
                //      can't outlive the host.
                viewModel.applyForegroundState(new == .active)
            }
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
        // First-launch onboarding sheet. Full-screen on iPhone via
        // the default sheet behaviour at the root of the
        // NavigationStack. Suppressed when the host was opened by
        // the keyboard extension — the user is mid-dictation flow,
        // not in setup-mode, and a sheet would block the recording
        // UI underneath. They'll see the sheet on the next plain
        // launch instead. Suppressed in the permission-denied state
        // too, since the denial wall already tells them what to do
        // and the sheet's first step would be unactionable.
        .sheet(isPresented: onboardingSheetBinding) {
            OnboardingSheet(viewModel: viewModel)
        }
        .task { await viewModel.requestPermissionIfNeeded() }
    }

    /// Hoisted out of `body` to keep the type-checker happy — Swift
    /// gets sluggish when a `Binding(get:set:)` lives inline next to
    /// half a dozen other view modifiers, and times out on the
    /// surrounding expression rather than this one. Putting it here
    /// also makes the suppression rules easier to read at a glance.
    private var onboardingSheetBinding: Binding<Bool> {
        Binding(
            get: {
                let denied = viewModel.permission == .denied
                let inKeyboardMode = keyboardRequest != nil
                return !onboardingCompleted && !inKeyboardMode && !denied
            },
            set: { newValue in
                // Mirror dismiss into persistence so a swipe-down
                // (if iOS ever bypasses interactiveDismissDisabled)
                // treats the sheet as "Skip for now" rather than
                // re-presenting on next launch.
                if newValue == false { onboardingCompleted = true }
            }
        )
    }

    /// Banner shown when the host was launched by the Dictator
    /// keyboard extension. Lets the user know why the app jumped to
    /// the front, that the result will fly back to the keyboard once
    /// they finish dictating, AND gives them an X to bail out — used
    /// when iOS leaves us stuck in keyboard mode (the previous-app
    /// link is gone, or they decided to keep using Dictator standalone).
    private var keyboardModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard mode")
                    .font(.footnote.weight(.semibold))
                Text("Dictate, then switch back to your previous app — the result will land where you were typing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                exitKeyboardMode()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit keyboard mode")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Tear down keyboard mode and abandon any in-flight recording.
    /// Calling `cancelRecording` rather than just clearing the
    /// session means tapping X while mid-dictation cleanly stops
    /// the recorder without firing transcription — otherwise a
    /// half-finished transcript would land in the local field a
    /// few seconds later, which the user described as confusing.
    private func exitKeyboardMode() {
        viewModel.cancelRecording()
        keyboardRequest = nil
        KeyboardBridge.clearRequest()
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
                    // Orange "unloaded" rather than green "ready" —
                    // the model is on disk but a first press has to
                    // warm it up, so calling it "ready" mis-sells the
                    // user on instant response. Three distinct
                    // colours map to three distinct states across the
                    // app and the keyboard.
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                    Text("Model unloaded")
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
                Task { await viewModel.confirmAndDownloadModel() }
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
        // Cellular confirmation. Presented when `confirmAndDownloadModel`
        // detects the device is on cellular (or the link is unknown) so
        // we don't kick off a ~460 MB download against the user's data
        // plan without their say-so. "Download anyway" is destructive-
        // styled to flag the data-plan consequence; "Wait for Wi-Fi" is
        // the default cancel.
        .alert(
            "Download over cellular?",
            isPresented: $viewModel.cellularConfirmationPending
        ) {
            Button("Wait for Wi-Fi", role: .cancel) {}
            Button("Download anyway", role: .destructive) {
                Task { await viewModel.downloadModel() }
            }
        } message: {
            Text("The Parakeet speech model is about 460 MB. You're on cellular — downloading now will count against your data plan. Connect to Wi-Fi for a faster, free download, or tap Download anyway to proceed.")
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

            if !keyboardOnboardingDismissed && !viewModel.isKeyboardMode {
                keyboardOnboardingCard
            }

            TranscriptCard(
                text: $viewModel.transcript,
                status: viewModel.status,
                focus: $transcriptFocused,
                // In keyboard mode the user is here from the keyboard
                // extension, mid-dictation flow — tapping into the
                // transcript would summon the system keyboard on top
                // of our UI and confuse the recording state. Lock the
                // field down until they exit keyboard mode via the X.
                isReadOnly: viewModel.isKeyboardMode
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
        .sheet(isPresented: $showingKeyboardSetup) {
            KeyboardSetupSheet()
        }
    }

    /// Dismissible onboarding card pointing the user at the Dictator
    /// keyboard. Visible only when the user hasn't dismissed it and
    /// isn't already in keyboard mode (no point nagging them about
    /// enabling something they're currently using). Auto-dismisses
    /// the first time a keyboard request arrives in `onChange` above.
    private var keyboardOnboardingCard: some View {
        Button {
            showingKeyboardSetup = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "keyboard.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(Color.purple.opacity(0.15))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Type with your voice anywhere")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Enable the Dictator keyboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Button {
                    keyboardOnboardingDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide this card")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Default layout: red mic + purple assist button (when AI is
    /// available) side by side, Copy as a wide bar above, status label
    /// + health warning underneath. In keyboard mode the upper button
    /// becomes "Switch back to your app" instead of Copy, and the
    /// mic uses tap-to-stop instead of hold-to-talk.
    private var fullControls: some View {
        VStack(spacing: 16) {
            if viewModel.isKeyboardMode {
                switchBackButton
            } else {
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
            }

            HStack(spacing: 28) {
                if viewModel.isKeyboardMode {
                    // Dispatch to the matching stop method —
                    // stopRecording finishes a normal dictation,
                    // stopAssistRecording runs the foundation-model
                    // transform on the surrounding text the keyboard
                    // captured. The single TapStopButton can't tell
                    // them apart, so the controller has to.
                    TapStopButton(status: viewModel.status) {
                        Task {
                            if viewModel.recordingMode == .assist {
                                await viewModel.stopAssistRecording()
                            } else {
                                await viewModel.stopRecording()
                            }
                        }
                    }
                } else {
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
            }

            StatusLabel(status: viewModel.status, mode: viewModel.recordingMode)
                .frame(height: 22)

            healthWarning
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Replaces the Copy button when the host was opened from the
    /// keyboard. Tapping shows a brief popover-style hint pointing
    /// the user at the system "← [App]" link in the top-left status
    /// bar — iOS doesn't expose a public API to programmatically
    /// return to the calling app, but it does render that link
    /// automatically when one app opens another via URL.
    private var switchBackButton: some View {
        Button {
            showingReturnHint = true
        } label: {
            Label("Switch back to your app", systemImage: "arrow.up.left.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
        .alert("Tap the link in the top-left", isPresented: $showingReturnHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iOS doesn't allow Dictator to switch you back automatically. Tap the system \"← \(callingAppHint)\" link in the top-left of the status bar — your transcribed text will land in the field you were typing in.")
        }
    }

    private var callingAppHint: String {
        // We don't know the calling app's display name (iOS doesn't
        // surface it), so use a generic placeholder.
        "previous app"
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
    /// When true the TextEditor is disabled — tapping it won't summon
    /// the system keyboard, and the field can't accept new keystrokes.
    /// Used during keyboard-extension flows to keep the system
    /// keyboard from popping up over Dictator's own recording UI.
    let isReadOnly: Bool

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
                .disabled(isReadOnly)

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

// MARK: - Tap-to-stop button (keyboard mode)

/// Tap variant used in keyboard mode. Recording is auto-started when
/// Rotating dashed ring drawn around the active listening button.
/// Sits outside the button face so it stays visible even when a
/// thumb is covering the button itself — the soft level-driven
/// pulse is great for audio-feedback texture but reads as little
/// more than a halo under most hands.
///
/// Driven by `TimelineView(.animation)` rather than a `@State`
/// rotation + repeatForever animation: the latter has a known
/// SwiftUI footgun where the rotation desynchronises after a view
/// re-instantiation. The timeline approach is purely a function
/// of `Date()`, so the ring picks up exactly where it should
/// regardless of how SwiftUI is recomposing the tree.
private struct ActiveListeningRing: View {
    let tint: Color
    /// Outer diameter of the ring — should sit outside the button
    /// the caller is decorating so a thumb-on-button doesn't occlude
    /// it.
    let diameter: CGFloat
    /// Stroke thickness. 3 pt reads cleanly at the button sizes used
    /// throughout the app; bump up for very large buttons.
    let lineWidth: CGFloat
    /// Seconds per full revolution. 4 s feels alive without looking
    /// frantic; slower than 6 s makes the motion easy to miss.
    let period: Double

    init(tint: Color, diameter: CGFloat, lineWidth: CGFloat = 3, period: Double = 4) {
        self.tint = tint
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.period = period
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation = (elapsed.truncatingRemainder(dividingBy: period) / period) * 360
            Circle()
                .strokeBorder(
                    tint,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        dash: [6, 10]
                    )
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(rotation))
        }
    }
}

/// the host receives a keyboard request, so the user shouldn't have
/// to hold anything down — they just tap once to STOP. Single
/// instance, no assist sibling.
private struct TapStopButton: View {
    let status: RecordingViewModel.Status
    let onTap: () -> Void

    private var level: Float {
        if case let .recording(level) = status { return level }
        return 0
    }

    private var icon: String {
        switch status {
        case .transcribing: "hourglass"
        case .recording, .warmingUp: "stop.fill"
        default: "mic.fill"
        }
    }

    private var disabled: Bool {
        switch status {
        case .transcribing: true
        default: false
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.18))
                    .frame(width: 96 + CGFloat(level) * 60, height: 96 + CGFloat(level) * 60)
                    .animation(.easeOut(duration: 0.08), value: level)
                // Spinning dashed ring sits just outside the button
                // face so it stays visible under a thumb — the pulse
                // is too soft to read while held.
                if status.isCapturing {
                    ActiveListeningRing(tint: .red, diameter: 120)
                }
                Circle()
                    .fill(.red)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
            .frame(width: 96 + 60, height: 96 + 60)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.7 : 1)
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
        let ringDiameter: CGFloat = diameter + (compact ? 14 : 24)
        let ringLineWidth: CGFloat = compact ? 2 : 3
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(
                    width: diameter + CGFloat(level) * ringMax,
                    height: diameter + CGFloat(level) * ringMax
                )
                .animation(.easeOut(duration: 0.08), value: level)

            // Spinning dashed listening ring — sits just outside the
            // button so the thumb doesn't occlude it. Only shows on
            // the active side via `isMyTurn` so the inactive button
            // stays calm.
            if isMyTurn, status.isCapturing {
                ActiveListeningRing(tint: tint, diameter: ringDiameter, lineWidth: ringLineWidth)
            }

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
