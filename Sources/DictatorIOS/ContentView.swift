import SwiftUI
import UIKit

struct ContentView: View {
    /// Optional keyboard-extension hand-off. When non-nil, the
    /// granted-content view shows a "Keyboard mode" banner and the
    /// view model will write the next successful transcript to the
    /// shared App Group container for the keyboard to insert.
    @Binding var keyboardRequest: KeyboardBridge.Request?

    @State private var viewModel = RecordingViewModel()
    /// True while the transcript editor holds focus (i.e. the user has
    /// tapped into the field). A plain `@State Bool` (not `@FocusState`)
    /// because the editor is UIKit-backed and pushes focus changes
    /// through the bridged binding instead of SwiftUI's focus subsystem.
    /// Note: focus alone doesn't necessarily mean the system keyboard
    /// is up — see `transcriptKeyboardEnabled` for that.
    @State private var transcriptFocused: Bool = false
    /// True when the user has explicitly requested the system keyboard
    /// via the bottom-center toggle on the transcript card. Default is
    /// false: the editor is selection-only (no keyboard) so iOS doesn't
    /// summon Dictator's own keyboard inside Dictator. When true, the
    /// UI flips to a focused edit mode — system keyboard at the
    /// bottom, transcript above, with the eraser / undo / mic / assist
    /// / copy chrome hidden so nothing competes with typing.
    @State private var transcriptKeyboardEnabled: Bool = false
    /// Mirrored to the bridge so the keyboard extension can both
    /// self-dismiss inside the Dictator app and freshness-check the
    /// model readiness chip (we only trust `loaded` while the host
    /// is actively heartbeating; a backgrounded or killed host ages
    /// out of the "ready" state).
    @Environment(\.scenePhase) private var scenePhase
    /// Shows the model-info sheet (status, unload). Driven by a tap
    /// on the persistent model-status chip in `grantedContent`.
    @State private var showingModelSheet = false
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
                // Arrival from the keyboard URL launch is now a
                // one-shot trigger: pre-populate the transcript,
                // auto-start the recording, dismiss the keyboard-
                // onboarding card (clear signal the user has it
                // installed), then immediately clear the binding so
                // we don't re-fire on subsequent renders.
                guard let req = new else { return }
                keyboardOnboardingDismissed = true
                if viewModel.permission == .granted {
                    viewModel.beginKeyboardRecording(
                        mode: req.mode,
                        surroundingText: req.surroundingText
                    )
                }
                keyboardRequest = nil
                KeyboardBridge.clearRequest()
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
            // No global tap-to-dismiss handler here. We used to have
            // `.contentShape(Rectangle()) + .onTapGesture` for that,
            // but SwiftUI's tap recognizer claims touches during its
            // detection window and that fought with the UITextView's
            // scroll gesture — swipes felt "swallowed" while the tap
            // recognizer waited to fail. Keyboard dismissal now goes
            // through the explicit toggle button on the transcript
            // card (and the system's swipe-down via
            // `keyboardDismissMode = .interactive`), so we don't need
            // a global handler at all.
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
                return !onboardingCompleted && !denied
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

    /// Active- (or paused-) download UI. Linear progress bar with
    /// bytes-downloaded / total, a smoothed transfer rate, and an
    /// explicit "you can leave the app" message — the underlying
    /// downloader runs over a background URLSession that keeps making
    /// progress while Dictator is suspended, so the user doesn't need
    /// to babysit the screen. Pause / Resume / Cancel let them control
    /// the transfer; resume data is persisted on disk so a paused
    /// download (or one interrupted by a network drop) picks up where
    /// it left off rather than restarting the whole 460 MB.
    private func downloadingView(snapshot: BackgroundModelDownloader.Progress, paused: Bool, pausedReason: String?) -> some View {
        let formatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            f.allowedUnits = [.useMB, .useGB]
            return f
        }()
        let downloaded = formatter.string(fromByteCount: max(0, snapshot.bytesDownloaded))
        let total = snapshot.bytesTotal > 0
            ? formatter.string(fromByteCount: snapshot.bytesTotal)
            : "—"
        let percent = Int(snapshot.fraction * 100)
        let rate: String? = (snapshot.bytesPerSecond > 1024 && !paused)
            ? "\(formatter.string(fromByteCount: Int64(snapshot.bytesPerSecond)))/s"
            : nil

        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: paused ? "pause.circle" : "arrow.down.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text(paused ? "Download paused" : "Downloading model…")
                .font(.title3.weight(.semibold))
            ProgressView(value: max(0, min(1, snapshot.fraction)))
                .progressViewStyle(.linear)
                .padding(.horizontal)
            VStack(spacing: 4) {
                Text("\(percent)%  ·  \(downloaded) of \(total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let rate {
                    Text(rate)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            // "Leave the app" reassurance — this is the headline UX
            // change. The previous version told users to keep Dictator
            // open; the background URLSession path removes that
            // requirement entirely.
            Text(paused
                 ? "Tap Resume to continue where you left off."
                 : "You can leave the app — the download will keep going in the background. Come back any time to check progress.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let pausedReason {
                Text(pausedReason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            HStack(spacing: 12) {
                if paused {
                    Button {
                        Task { await viewModel.downloadModel() }
                    } label: {
                        Text("Resume")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await viewModel.pauseDownload() }
                    } label: {
                        Text("Pause")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    Task { await viewModel.cancelDownload() }
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            Spacer()
        }
    }

    /// Failure UI. "Try again" rewinds to `.notDownloaded` so the CTA
    /// reappears and the user can try again — the background downloader
    /// will resume from the last completed file (and the in-flight
    /// file's resume data if available), not restart from zero.
    /// "Try later" exits the download flow so the user isn't trapped
    /// inside a permanently-failed onboarding screen on a flaky
    /// connection.
    private func downloadFailedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.orange)
            Text("Download interrupted")
                .font(.title3.weight(.semibold))
            Text(reason)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Text("Your progress so far is saved. Tap Try again to resume from where you left off — Dictator won't restart the whole download.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                Task { await viewModel.downloadModel() }
            } label: {
                Text("Try again")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            Button {
                viewModel.resetDownload()
            } label: {
                Text("Come back later")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .font(.body)
            }
            .buttonStyle(.bordered)
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
        case .downloading(_, let snapshot):
            downloadingView(snapshot: snapshot, paused: false, pausedReason: nil)
        case .paused(let snapshot, let reason):
            downloadingView(snapshot: snapshot, paused: true, pausedReason: reason)
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
            // Status row hidden in keyboard-edit mode — the user is
            // focused on typing and the chip + pill aren't actionable
            // here. Reclaiming the strip gives the transcript card
            // another ~38pt of vertical breathing room above the
            // system keyboard.
            if !transcriptKeyboardEnabled {
                HStack {
                    modelStatusChip
                    Spacer()
                    statusPill
                }
            }

            if !keyboardOnboardingDismissed && !transcriptKeyboardEnabled {
                keyboardOnboardingCard
            }

            TranscriptCard(
                text: $viewModel.transcript,
                selection: $viewModel.transcriptSelection,
                status: viewModel.status,
                focus: $transcriptFocused,
                keyboardEnabled: $transcriptKeyboardEnabled
            )
            .frame(maxHeight: .infinity)
            // Floating clear button (bottom-leading) — explicit "blank
            // slate" so multi-shot dictation has an obvious reset.
            // Snapshots to previousTranscript first so undo recovers
            // a misfired clear. Hidden in keyboard-edit mode — that's
            // a focused typing surface and the eraser only adds noise.
            .overlay(alignment: .bottomLeading) {
                if viewModel.canClear && !transcriptKeyboardEnabled {
                    ClearButton(action: viewModel.clear)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Floating undo button (bottom-trailing) — visible only
            // when there's a snapshot to swap to. Toggles
            // current ↔ previous so a second tap acts as redo. Sits
            // opposite the clear button so the two destructive /
            // reversible actions mirror each other. Also hidden in
            // keyboard-edit mode (UITextView's own undo via shake /
            // three-finger gesture takes over there).
            .overlay(alignment: .bottomTrailing) {
                if viewModel.canUndo && !transcriptKeyboardEnabled {
                    UndoButton(action: viewModel.undo)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Floating keyboard toggle (bottom-center) — by default the
            // editor accepts selection / cursor gestures without
            // summoning the system keyboard (which would otherwise
            // pop up Dictator's own keyboard inside Dictator, since
            // it's the user's default). Tap to opt in to typing.
            // Hidden in read-only keyboard-extension mode where
            // tapping anything in the transcript would derail the
            // recording flow, and also hidden when there's no text
            // yet — nothing to edit means no need for the button or
            // the gesture surface it gates.
            .overlay(alignment: .bottom) {
                if !viewModel.transcript.isEmpty {
                    KeyboardToggleButton(enabled: transcriptKeyboardEnabled) {
                        // Explicit withAnimation so the control-layout
                        // swap below crossfades cleanly. The
                        // `.animation(value:)` modifier on the parent
                        // catches state changes that come back through
                        // the delegate (swipe-dismiss), but the toggle
                        // itself benefits from an explicit context so
                        // the springs all fire from the same source.
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            transcriptKeyboardEnabled.toggle()
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.canUndo)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: viewModel.canClear)

            // Keyboard-enabled mode is a focused editor — system
            // keyboard at the bottom, transcript above, and nothing
            // else competing for attention. When not in that mode,
            // surface the full set of mic / assist / copy controls.
            if !transcriptKeyboardEnabled {
                fullControls
            }
        }
        // Mic shrink, copy reshape, and status label fade ride a
        // single spring so the swap reads as one motion. Bound to the
        // same value the conditional keys off so SwiftUI knows to
        // animate the diff.
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: transcriptKeyboardEnabled)
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
    /// + health warning underneath. The Copy button is identical in
    /// keyboard mode and in-app mode — every successful transcription
    /// auto-copies to the clipboard anyway, so Copy is just a manual
    /// re-sync for "I edited this and want the new version on the
    /// clipboard now."
    private var fullControls: some View {
        VStack(spacing: 12) {
            // Warning / error caption sits ABOVE the action buttons
            // now, in the slot the dynamic StatusLabel used to fill.
            // The status pill at the top of the screen already shows
            // the dictation lifecycle (Idle / Waiting / Transcribing),
            // so a second copy here was redundant — replacing it with
            // the standing warning frees vertical space and reads
            // calmer. Error state flips the same line red so a
            // failure still surfaces in the place the user's eye is
            // drawn during action.
            warningOrError

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
                if viewModel.autoStartedRecordingActive {
                    // Recording was started for the user (keyboard URL
                    // launch path), not by a button press — a hold-to-
                    // talk affordance is wrong here, so a tap-to-stop
                    // mirrors the way the user got into the recording.
                    // Tint + resting icon match the matching in-app
                    // button so the user can tell at a glance whether
                    // they're in a dictate (red) or assist (purple) flow.
                    TapStopButton(
                        status: viewModel.status,
                        tint: viewModel.recordingMode == .assist ? .purple : .red,
                        restingIcon: viewModel.recordingMode == .assist ? "wand.and.stars" : "mic.fill"
                    ) {
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
                        restingIcon: micRestingIcon,
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
        }
        // Pure crossfade with the compact variant — when the layouts
        // differ this much (vertical stack vs single horizontal row),
        // sliding from an edge made the larger block visibly jump
        // through the smaller one. A clean opacity blend reads as a
        // single morph rather than two separate gestures.
        .transition(.opacity)
    }

    /// Standing footer that doubles as the error surface. Renders the
    /// on-device-assistant best-effort warning by default; on a
    /// `.error` status it swaps in the failure message in red. The
    /// status pill at the top of the screen handles the rest of the
    /// lifecycle (idle / recording / transcribing), so we don't
    /// duplicate any of that here.
    @ViewBuilder
    private var warningOrError: some View {
        if case .error(let message) = viewModel.status {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("The on-device assistant runs locally and can make mistakes. Always read the result back before relying on it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// True while the pill should render its bars panel rather than a
    /// text label. Warm-up shows zero-level bars (no samples yet) so
    /// the meter starts at rest and animates up as soon as the first
    /// buffer lands.
    private var showsRecordingWaveform: Bool {
        switch viewModel.status {
        case .warmingUp, .recording: true
        default: false
        }
    }

    /// Current RMS level fed into the waveform. Zero outside the
    /// `.recording(level:)` case.
    private var currentLevel: Float {
        if case let .recording(level) = viewModel.status { return level }
        return 0
    }

    /// Status pill sitting opposite the model-status chip. Mirrors the
    /// existing chip's secondarySystemBackground capsule so the two
    /// read as a matched pair, and morphs between three states:
    ///   - `.idle` / `.ready` / `.error` → small "Idle" label.
    ///   - `.warmingUp` / `.recording`   → live waveform.
    ///   - `.transcribing`               → "Transcribing" / "Applying"
    ///     with a small spinner.
    /// Fixed width (150pt) so the morph stays visually stable — a
    /// content-sized capsule would jump width between the short label
    /// states and the much-wider waveform state and shift the chip
    /// across the row by a few pixels each time. Error detail still
    /// lives in the StatusLabel below the buttons; the pill only
    /// shows the coarse state.
    private var statusPill: some View {
        ZStack {
            // Resting label — visible when neither waveform nor
            // transcribing slots are showing. Stacked rather than
            // branched so the pill's intrinsic size doesn't bounce
            // when SwiftUI's transition crossfades the states.
            // Appends the most recent transcription's duration when
            // we have one ("Idle · 1.2s") so the user can see how
            // snappy the round-trip was without digging into stats.
            Text(idlePillLabel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(isIdleStatus ? 1 : 0)

            // Live "we're listening" meter. `.id(...)` on the
            // recording counter forces a fresh component on each new
            // press — without it the Waveform's internal @State
            // carries the prior run's bars over, and the leftover
            // bars flash visible the instant the new recording
            // starts. Hit-testing off so the invisible-state meter
            // can't intercept taps in the gap.
            Waveform(
                level: currentLevel,
                tint: viewModel.recordingMode == .assist ? .purple : .red,
                height: 22
            )
            .id(viewModel.recordingStartCount)
            .padding(.horizontal, 6)
            .opacity(showsRecordingWaveform ? 1 : 0)
            .allowsHitTesting(false)

            // Transcribing / applying / waiting state. Spinner + a
            // short label that explains *what* we're waiting on:
            //   - Model still loading → "Waiting" (so the user knows
            //     the first-run lag isn't actual inference time)
            //   - Assist transform     → "Applying"
            //   - Normal transcription → "Transcribing"
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text(transcribingPillLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(isTranscribingStatus ? 1 : 0)
        }
        .frame(width: 150, height: 30)
        .background(Capsule().fill(Color(.secondarySystemBackground)))
        .animation(.easeInOut(duration: 0.18), value: showsRecordingWaveform)
        .animation(.easeInOut(duration: 0.18), value: isTranscribingStatus)
        .animation(.easeInOut(duration: 0.18), value: isIdleStatus)
    }

    /// Idle pill text. "Idle" alone until the first successful
    /// transcription lands, then "Idle · 1.2s" so the user can see the
    /// round-trip time. Resets back to bare "Idle" on clear() or on a
    /// failed run.
    private var idlePillLabel: String {
        if let duration = viewModel.lastTranscriptionDuration {
            return "Idle · \(formatPillDuration(duration))"
        }
        return "Idle"
    }

    /// "Waiting" while the model is still being loaded into memory —
    /// the wait there isn't inference time, it's the first-press model
    /// load, and labelling it "Transcribing" would mis-sell the speed.
    /// Otherwise mode-appropriate ("Applying" for assist, plain
    /// "Transcribing" for dictation).
    private var transcribingPillLabel: String {
        if viewModel.isModelLoading { return "Waiting" }
        return viewModel.recordingMode == .assist ? "Applying" : "Transcribing"
    }

    private func formatPillDuration(_ seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    private var isIdleStatus: Bool {
        switch viewModel.status {
        case .idle, .ready, .error: true
        default: false
        }
    }

    private var isTranscribingStatus: Bool {
        if case .transcribing = viewModel.status { return true }
        return false
    }

    /// Icon shown on the red mic when it isn't actively recording.
    /// Three states hint at what the next press will actually do:
    ///   - empty transcript                → plain mic (fresh capture)
    ///   - non-empty, selection active     → ellipsis badge (will
    ///     replace the highlighted range with the dictation)
    ///   - non-empty, no selection / caret → plus badge (will append
    ///     at the end or insert at the caret)
    private var micRestingIcon: String {
        if viewModel.transcript.isEmpty { return "microphone.fill" }
        if (viewModel.transcriptSelection?.length ?? 0) > 0 {
            return "microphone.badge.ellipsis.fill"
        }
        return "microphone.badge.plus.fill"
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
    /// Live caret / selection range. Bound back to the view model so
    /// transcribed chunks can land at the user's cursor (or replace a
    /// highlighted range) instead of always appending at the end.
    @Binding var selection: NSRange?
    let status: RecordingViewModel.Status
    /// Plain `Binding<Bool>` (not `@FocusState.Binding`) — the editor
    /// is a UIKit wrapper that mirrors first-responder changes through
    /// here instead of through SwiftUI's focus subsystem.
    @Binding var focus: Bool
    /// True when the system keyboard should actually appear. When
    /// false the editor stays selectable and cursor-positionable but
    /// the keyboard never appears (driven entirely by `isEditable`
    /// on the underlying UITextView). Drives the keyboard-icon
    /// overlay's on/off visual.
    @Binding var keyboardEnabled: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            // UIKit-backed editor. SwiftUI's TextEditor(text:selection:)
            // on iOS 26 was eating drag-select gestures — switching to
            // a UITextView wrapper restores normal selection behaviour
            // and lets the view model receive cursor / range updates
            // reliably for cursor-aware insertion.
            EditableTranscript(
                text: $text,
                selection: $selection,
                isFocused: $focus,
                keyboardEnabled: $keyboardEnabled
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 4)

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

// MARK: - UIKit-backed transcript editor

/// `UITextView` wrapper that exposes text, selection, and focus as
/// SwiftUI bindings. We need this because SwiftUI's `TextEditor`
/// `selection:` binding on iOS 26 was interfering with drag-select —
/// the user couldn't highlight any text in the transcript card. With
/// a hand-rolled UIViewRepresentable the platform's normal selection
/// behaviour (long-press loupe, double-tap word, drag handles) all
/// work as expected, and we still get the selection plumbing the
/// cursor-aware merge needs.
private struct EditableTranscript: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool
    @Binding var keyboardEnabled: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        // Match the visual padding the old TextEditor had — the parent
        // ZStack already provides the card chrome, so we just need
        // breathing room inside the text view.
        // Bottom inset reserves a strip the floating clear /
        // keyboard / undo buttons can sit on without overlapping the
        // last lines of text. 50pt = 36pt button + 6pt overlay
        // padding + a small breathing gap.
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 50, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.alwaysBounceVertical = true
        // Deliberately *not* setting `keyboardDismissMode = .interactive`
        // here: that mode mixes the scroll pan gesture with keyboard
        // dismissal tracking, and the user reported scrolls feeling
        // "swallowed" when the dismissal logic claimed part of the
        // drag. Dismissal goes through the explicit keyboard toggle
        // button on the transcript card instead.
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Refresh the coordinator's parent pointer so its delegate
        // callbacks read the current bindings (Swift value semantics —
        // a fresh `self` is generated on every SwiftUI invalidation).
        context.coordinator.parent = self

        // Setting `text` and setting `selectedRange` both fire the
        // delegate synchronously. Bracket the programmatic mutations
        // with a suppress flag so the echoes don't mirror back into
        // the bindings and clobber what `mergeTranscribed` (or any
        // other model write) just established. Synchronous flip is
        // critical: an async re-enable raced with real user taps and
        // suppressed them, breaking tap-to-position-cursor.
        context.coordinator.suppressDelegateMirror = true
        defer { context.coordinator.suppressDelegateMirror = false }

        let textChanged = uiView.text != text
        if textChanged {
            uiView.text = text
        }

        // Apply the model's selection when it's valid; fall back to
        // clamping the view's prior selection if the text shrank under
        // us (e.g. undo). When the model says nothing and the text
        // didn't change, leave the view's selection alone — important
        // so taps that update the model don't immediately bounce.
        let length = (text as NSString).length
        let targetSelection: NSRange? = {
            if let sel = selection,
               sel.location >= 0,
               sel.location + sel.length <= length {
                return sel
            }
            if textChanged {
                let saved = uiView.selectedRange
                let loc = min(saved.location, length)
                let len = min(saved.length, length - loc)
                return NSRange(location: loc, length: len)
            }
            return nil
        }()
        if let target = targetSelection, !NSEqualRanges(uiView.selectedRange, target) {
            uiView.selectedRange = target
        }

        // `isEditable` IS the keyboard toggle. Standard UITextView
        // semantics: editable view summons the system keyboard on
        // first-responder; non-editable view doesn't. With
        // `isSelectable=true` the user can still long-press for the
        // loupe to position the cursor and drag handles to select,
        // even when isEditable=false — so the "look, no keyboard"
        // default mode keeps full selection / cursor-positioning
        // gesture support without iOS summoning the system (and
        // therefore Dictator's own) keyboard on tap.
        uiView.isEditable = keyboardEnabled && !text.isEmpty
        uiView.isSelectable = true

        // Drive focus from the toggle, but ONLY on actual transitions
        // of `keyboardEnabled`. Polling every updateUIView was racing
        // with the user's gestures: long-press for selection makes
        // the view first responder (it has to, for the selection
        // menu to appear), then the next SwiftUI re-render saw
        // "keyboardEnabled=false && isFirstResponder=true" and
        // queued an async `resignFirstResponder` — which could fire
        // mid-scroll and cancel the gesture. Comparing against the
        // coordinator's last-seen value means we only act when the
        // toggle is the actual cause.
        if keyboardEnabled != context.coordinator.lastKeyboardEnabled {
            context.coordinator.lastKeyboardEnabled = keyboardEnabled
            if keyboardEnabled {
                DispatchQueue.main.async { uiView.becomeFirstResponder() }
            } else if uiView.isFirstResponder {
                DispatchQueue.main.async { uiView.resignFirstResponder() }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditableTranscript
        /// True while `updateUIView` is applying model state to the
        /// underlying UITextView. Selection / text delegate callbacks
        /// fired during that window are echoes of our own writes, not
        /// user interactions — skipping them keeps the model's value
        /// from being round-tripped over the top of what we just set.
        /// Flipped synchronously; UIKit fires these delegates
        /// synchronously from `text =` / `selectedRange =`, so the
        /// flag is always cleared by the time the next real user event
        /// arrives on the runloop.
        var suppressDelegateMirror = false
        /// Last value of `keyboardEnabled` we observed on an update.
        /// `updateUIView` only triggers a focus change when this
        /// disagrees with the incoming value — so a SwiftUI re-render
        /// for some unrelated reason (selection delegate fired, parent
        /// state changed) doesn't keep yanking the responder around.
        var lastKeyboardEnabled = false

        init(parent: EditableTranscript) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !suppressDelegateMirror else { return }
            if parent.text != textView.text {
                parent.text = textView.text
            }
            let r = textView.selectedRange
            if parent.selection != r { parent.selection = r }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !suppressDelegateMirror else { return }
            // Only mirror selection back when the user is actively
            // editing — UITextView's default selection (0,0) on a
            // never-focused view would otherwise look like "caret at
            // position 0" and trick the merge into inserting at the
            // start of the transcript instead of the end.
            guard textView.isFirstResponder else { return }
            let r = textView.selectedRange
            if parent.selection != r { parent.selection = r }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
            // Resign also dismisses the keyboard, so the toggle
            // shouldn't keep claiming "keyboard on" — sync it down
            // so the next tap on the editor doesn't immediately
            // resummon the keyboard via the becomeFirstResponder
            // branch in updateUIView.
            if parent.keyboardEnabled { parent.keyboardEnabled = false }
        }
    }
}


// MARK: - Undo / Clear buttons

/// Floating undo button on the bottom-trailing edge of the transcript
/// card. Capsule with icon + label — the standalone arrow glyph was
/// ambiguous (users read it as a back button, not "undo the last
/// transcript change"); the word removes the doubt.
private struct UndoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo")
    }
}

/// Mirror of `UndoButton` on the bottom-leading edge. We don't gate
/// on a confirmation dialog — undo sits right next to it for one-tap
/// recovery, which is the right tradeoff versus a two-tap confirmation
/// for what is otherwise the most-used "start fresh" action.
private struct ClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Clear", systemImage: "eraser.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear transcript")
    }
}

/// Bottom-center toggle for opting in / out of the system keyboard.
/// Default state is "off" (no keyboard) so the editor handles cursor
/// + selection gestures without iOS summoning the user's default
/// keyboard — which on a Dictator user's device is Dictator's own
/// keyboard, and rendering it inside Dictator was the "inception-y"
/// experience the user wanted to avoid. Tap to bring up the keyboard
/// for typing; tap again (or swipe down on the keyboard) to put it
/// away again.
private struct KeyboardToggleButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // `keyboard.chevron.compact.down` is iOS's standard
            // "dismiss the keyboard" glyph — same one Notes, Mail,
            // and Messages put in their toolbars. Reuse it when the
            // toggle is on so the affordance reads as "tap to put the
            // keyboard away" rather than "this is the keyboard
            // button" (which is what the plain icon suggests).
            Image(systemName: enabled ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.callout.weight(.semibold))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Hide keyboard" : "Show keyboard")
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
    /// Tint for the pulse, ring, and button face. Red for dictate,
    /// purple for assist — matches the in-app HoldButton pairing so
    /// the user can tell which flow they're in even when the auto-
    /// started recording is the only on-screen button.
    let tint: Color
    /// Glyph shown when the button isn't actively recording /
    /// transcribing (idle / ready / error). Recording uses "stop.fill"
    /// and transcribing uses "hourglass" regardless of mode.
    let restingIcon: String
    let onTap: () -> Void

    private var level: Float {
        if case let .recording(level) = status { return level }
        return 0
    }

    private var icon: String {
        switch status {
        case .transcribing: "hourglass"
        case .recording, .warmingUp: "stop.fill"
        default: restingIcon
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
                    .fill(tint.opacity(0.18))
                    .frame(width: 96 + CGFloat(level) * 60, height: 96 + CGFloat(level) * 60)
                    .animation(.easeOut(duration: 0.08), value: level)
                // Spinning dashed ring sits just outside the button
                // face so it stays visible under a thumb — the pulse
                // is too soft to read while held.
                if status.isCapturing {
                    ActiveListeningRing(tint: tint, diameter: 120)
                }
                Circle()
                    .fill(tint)
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

/// Round dual-mode button shared between the red mic (records
/// dictation) and the purple assist wand (records an instruction to
/// apply to the current transcript). Same gesture shape, different
/// tint + icon + action.
///
/// Two interaction modes resolved from the gesture itself:
///   - **Tap** (press + release within ~0.35s): toggle-on. Recording
///     starts on press and continues after the finger lifts; a second
///     tap stops it. Useful for longer dictation sessions where you
///     don't want to keep your thumb pinned.
///   - **Hold** (press for longer than the threshold): push-to-talk.
///     Recording starts on press and stops on release. Useful for
///     quick voice messages — you don't have to consciously think
///     about stopping it.
///
/// The mode is decided at release time from the press duration — no
/// upfront commitment, no second gesture, no menu. From the parent's
/// perspective the contract is unchanged: `onPress` fires once on
/// initial touch, `onRelease` fires once when the recording should
/// stop (on release for push-to-talk, on the second tap for toggle).
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
    /// True after a tap-and-release shorter than `holdThreshold` — the
    /// button is now in "toggle on" mode and the next tap stops the
    /// recording. False during push-to-talk (held longer than the
    /// threshold) and after the recorder finishes for any reason.
    @State private var isLatched = false
    /// Wall-clock time the current press started, used at release time
    /// to decide tap vs. hold. Cleared on release.
    @State private var pressStartedAt: Date?

    /// Press-duration boundary between "this was a tap" and "this is a
    /// hold". 0.35s is short enough that a deliberate tap feels
    /// instant and long enough that a momentary fumble doesn't get
    /// misread as the toggle path.
    private static let holdThreshold: TimeInterval = 0.35

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
        if isMyTurn, isLatched {
            // Latched into tap-to-toggle mode — swap the resting icon
            // for `stop.fill` so the next-tap-stops affordance is
            // obvious. The hold path doesn't get an icon swap because
            // the user's thumb is on the button while the press is
            // active; the scaleEffect + listening ring already cover
            // "you are recording".
            return "stop.fill"
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
            // onPressingChanged so we can implement the tap-vs-hold
            // split on release rather than committing up front.
        } onPressingChanged: { pressing in
            if pressing, !isPressed {
                isPressed = true
                if isLatched {
                    // Already toggled on from a previous tap — this
                    // press is the tap-to-stop. Defer the stop to
                    // release for consistency with how iOS native
                    // toggle controls behave (touch-up-inside) and so
                    // a fumbled touch doesn't kill the recording.
                } else {
                    pressStartedAt = Date()
                    onPress()
                }
            } else if !pressing, isPressed {
                isPressed = false
                if isLatched {
                    // Second tap on a latched button — stop the
                    // recording and clear the latch regardless of
                    // press duration.
                    isLatched = false
                    onRelease()
                } else {
                    let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    pressStartedAt = nil
                    if elapsed >= Self.holdThreshold {
                        // Push-to-talk: held past the threshold, so
                        // release stops the recording.
                        onRelease()
                    } else {
                        // Tap: latch on, recording continues until the
                        // next tap.
                        isLatched = true
                    }
                }
            }
        }
        // Auto-clear the latch if the recorder finishes for any other
        // reason (auto-finish, transcription error, the parent flipping
        // to autoStartedRecordingActive, etc.) — otherwise a stale
        // latch would leave the button thinking it's "on" with nothing
        // actually recording, and the next tap would silently start a
        // brand-new recording instead of cancelling the "active"
        // state the user expects.
        .onChange(of: isMyTurn) { _, nowMine in
            if !nowMine { isLatched = false }
        }
        .onChange(of: statusKey) { _, _ in
            if !status.isCapturing,
               !{ if case .transcribing = status { return true } else { return false } }() {
                isLatched = false
            }
        }
    }

    /// Coarse identifier for the current status case — used as the
    /// `.onChange` value so we react when the recorder transitions
    /// across phases (e.g. recording → transcribing → idle) without
    /// firing on every level update inside `.recording(level:)`.
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

#Preview {
    ContentView()
}
