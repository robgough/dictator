import AppKit
import AVFoundation
import SwiftUI

/// First-run setup wizard. Walks new users through the three things they'd
/// otherwise have to discover inside Settings before dictation works:
///   1. Welcome / what this app is.
///   2. Mic + Accessibility grants (without these, dictation is dead in the water).
///   3. Picking and downloading a transcription model (and optionally an LLM).
///   4. The hotkey to actually use.
///
/// The window is shown once on first launch when
/// `settings.hasCompletedOnboarding == false`, and is re-openable from the menu
/// bar's "Setup…" entry. Finishing or explicitly skipping the wizard flips
/// the flag so it doesn't reappear next launch.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let appState: AppState
    private let onFinished: () -> Void

    init(appState: AppState, onFinished: @escaping () -> Void) {
        self.appState = appState
        self.onFinished = onFinished
    }

    /// Bring the wizard to the front. Re-uses the same NSWindow across calls
    /// so a re-open from the menu bar lands on the same window state.
    func show() {
        let window = ensureWindow()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        // NSHostingController gives the wizard its own SwiftUI scene, so the
        // `.environment(appState)` applied to MenuBarExtra at the App level
        // isn't visible here — we have to re-inject it ourselves or any
        // child view using `@Environment(AppState.self)` will fatal-error at
        // first access.
        let root = OnboardingView(
            onComplete: { [weak self] in
                self?.window?.performClose(nil)
                self?.onFinished()
            },
            onSkip: { [weak self] in
                self?.window?.performClose(nil)
                self?.onFinished()
            }
        )
        .environment(appState)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to Dictator"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentViewController = NSHostingController(rootView: root)
        window = w
        return w
    }

    /// Closing the wizard via the title bar X counts the same as Skip — we
    /// don't want it to reappear on next launch just because they closed
    /// the window. The user can always reopen from the menu bar.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            onFinished()
        }
    }
}

// MARK: - Root view

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case models
    case ready

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .models: "Models"
        case .ready: "Ready"
        }
    }
}

private struct OnboardingView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var step: OnboardingStep = .welcome
    /// Mirrors `MicPermission.status()` so we can gate the Continue button
    /// without forcing every step view to bubble the same value back up.
    /// Mic access is the one non-negotiable permission — without it the
    /// pipeline literally has no audio to transcribe — so we block forward
    /// progress on the Permissions step until it's authorized OR denied
    /// (denied means the OS won't pop the prompt again; the user has to
    /// flip the toggle in System Settings, and we let them continue and
    /// come back to it rather than wedging the wizard).
    @State private var micStatus: AVAuthorizationStatus = MicPermission.status()
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 18)

            Group {
                switch step {
                case .welcome:     WelcomeStep()
                case .permissions: PermissionsStep()
                case .models:      ModelsStep()
                case .ready:       ReadyStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
        .frame(width: 620, height: 540)
        .onReceive(pollTimer) { _ in
            micStatus = MicPermission.status()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip setup", action: onSkip)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

            Spacer()

            if step == .permissions, micStatus == .notDetermined {
                Text("Mic access required to continue")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if step != .welcome {
                Button("Back") { advance(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }

            if step == .ready {
                Button("Finish", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { advance(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .permissions && micStatus == .notDetermined)
            }
        }
    }

    private func advance(by delta: Int) {
        let next = step.rawValue + delta
        if let candidate = OnboardingStep(rawValue: next) {
            withAnimation(.easeInOut(duration: 0.18)) { step = candidate }
        }
    }
}

// MARK: - Step indicator

/// Slim numbered-step strip. Each step claims an equal-width slot in an
/// HStack; the dot sits centred in its slot and the label centres directly
/// below the dot. The horizontal track connects the centres of the first
/// and last dots, so the filled portion always lines up with the dot the
/// user has reached. Dropping per-step `Rectangle` connectors into the
/// HStack made the line tremble vertically as label widths changed; one
/// continuous track avoids that.
private struct StepIndicator: View {
    let current: OnboardingStep

    private let dotSize: CGFloat = 18
    private let trackHeight: CGFloat = 2

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let count = OnboardingStep.allCases.count
                let progress = max(0, min(1, Double(current.rawValue) / Double(count - 1)))
                let width = proxy.size.width
                let slot = width / CGFloat(count)
                let firstCenter = slot / 2
                let lastCenter = width - slot / 2
                let trackWidth = lastCenter - firstCenter

                ZStack(alignment: .leading) {
                    // Background track — runs from first dot centre to last
                    // dot centre so the visual line never extends past the
                    // endpoints.
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: trackWidth, height: trackHeight)
                        .offset(x: firstCenter)

                    // Filled portion up to the current step's dot centre.
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: trackWidth * CGFloat(progress), height: trackHeight)
                        .offset(x: firstCenter)
                        .animation(.easeInOut(duration: 0.25), value: progress)

                    // Dots positioned at the centre of each equal-width slot —
                    // matches the centres of the labels in the HStack below.
                    ForEach(OnboardingStep.allCases, id: \.self) { s in
                        let centerX = slot * (CGFloat(s.rawValue) + 0.5)
                        dot(for: s)
                            .offset(x: centerX - dotSize / 2)
                    }
                }
                .frame(height: dotSize)
            }
            .frame(height: dotSize)

            HStack(spacing: 0) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Text(s.title)
                        .font(.system(size: 11, weight: s == current ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(s == current ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func dot(for s: OnboardingStep) -> some View {
        let isCurrent = s == current
        let isDone = s.rawValue < current.rawValue

        ZStack {
            Circle()
                .fill(isDone || isCurrent ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                .frame(width: dotSize, height: dotSize)
                .overlay(
                    Circle().strokeBorder(
                        isDone || isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: 1.5
                    )
                )
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            } else if isCurrent {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .animation(.easeInOut(duration: 0.18), value: isDone)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 30, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Dictator")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Local-first dictation for macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                BulletRow(icon: "mic.fill", title: "Hold a hotkey to dictate",
                          detail: "Speak, release the key, and the transcript lands in whichever app has focus.")
                BulletRow(icon: "cpu", title: "Everything runs on your Mac",
                          detail: "Speech and language models run entirely on-device. No audio or text leaves your machine.")
                BulletRow(icon: "wand.and.stars", title: "Optional formatting passes",
                          detail: "A small local LLM can clean up grammar and add structure — only if you want it.")
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                Text("Three quick steps and you're set: grant permissions, download a transcription model, then dictate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                MachineRAMNote()
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tells the user up-front what we've detected and what that means for the
/// defaults they're about to see. Honest about the trade-off so the
/// recommendation on the Models step (No LLM on lean Macs, smaller LLM on
/// 16 GB, full 3B on 24 GB+) doesn't read as arbitrary.
private struct MachineRAMNote: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip")
                .foregroundStyle(tint)
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }

    private var message: String {
        let total = SystemMemory.totalGBLabel
        switch SystemMemory.tier {
        case .lean:
            return "Detected \(total) of RAM — we'll keep things lean and skip the LLM by default. Dictator still works great; you'll get raw transcripts that just paste through."
        case .balanced:
            return "Detected \(total) of RAM — we'll default to a small LLM (Llama 3.2 1B) that fits comfortably alongside the transcription model."
        case .generous:
            return "Detected \(total) of RAM — comfortable for the full setup, including the recommended Llama 3.2 3B for formatting."
        }
    }

    private var tint: Color {
        switch SystemMemory.tier {
        case .lean: .orange
        case .balanced, .generous: .accentColor
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22, height: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(
                title: "Grant the permissions Dictator needs",
                detail: "macOS asks before any app can listen to the microphone or paste into another window."
            )

            MicPermissionCard()
            AccessibilityPermissionCard()

            Spacer(minLength: 0)

            Text("**Microphone** is required — without it Dictator can't record audio to transcribe. **Accessibility** is optional; if you skip it, transcripts copy to the clipboard and you paste with ⌘V manually.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StepHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MicPermissionCard: View {
    @State private var status: AVAuthorizationStatus = MicPermission.status()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        PermissionCard(
            icon: "mic.fill",
            title: "Microphone",
            badge: "Required",
            badgeTint: .accentColor,
            description: description,
            state: cardState
        ) {
            actionButton
        }
        .onReceive(pollTimer) { _ in status = MicPermission.status() }
    }

    private var description: String {
        switch status {
        case .authorized:
            return "Granted — Dictator can hear you."
        case .denied, .restricted:
            return "Denied. Open System Settings → Privacy & Security → Microphone and enable Dictator, then come back here."
        case .notDetermined:
            return "Required — Dictator can't transcribe without microphone access."
        @unknown default:
            return "Unknown status."
        }
    }

    private var cardState: PermissionCardState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .pending
        case .denied, .restricted: .denied
        @unknown default: .pending
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch status {
        case .notDetermined:
            Button("Grant access") {
                MicPermission.request { granted in
                    Task { @MainActor in
                        status = MicPermission.status()
                        if !granted { openMicrophoneSettings() }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        case .denied, .restricted:
            Button("Open Settings") { openMicrophoneSettings() }
        case .authorized:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AccessibilityPermissionCard: View {
    @State private var granted: Bool = TextInjector.hasAccessibilityPermission()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        PermissionCard(
            icon: "hand.tap.fill",
            title: "Accessibility",
            badge: "Optional",
            badgeTint: .secondary,
            description: granted
                ? "Granted — Dictator can paste into the focused app."
                : "Lets Dictator paste transcripts into whichever app you're using. Without it, transcripts only copy to the clipboard.",
            state: granted ? .granted : .pending
        ) {
            if !granted {
                Button("Grant access") {
                    // Two-step gesture: register Dictator in macOS's AX list, then
                    // open the Privacy pane so the user has somewhere to flip the
                    // toggle. The AX prompt also pops its own confirmation dialog.
                    TextInjector.requestAccessibilityPrompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onReceive(pollTimer) { _ in granted = TextInjector.hasAccessibilityPermission() }
    }
}

private enum PermissionCardState {
    case granted, pending, denied

    var icon: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .pending: "circle"
        case .denied:  "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .pending: .secondary
        case .denied:  .orange
        }
    }
}

private struct PermissionCard<Trailing: View>: View {
    let icon: String
    let title: String
    let badge: String
    let badgeTint: Color
    let description: String
    let state: PermissionCardState
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 17, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(badgeTint.opacity(0.15))
                        )
                    Image(systemName: state.icon)
                        .foregroundStyle(state.color)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - Step 3: Models

private struct ModelsStep: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared

    /// Recommended speech-to-text model. We hard-wire Parakeet v3 in the
    /// wizard — it's faster than Whisper on Apple Silicon, smaller on disk,
    /// and covers 25 European languages. Power users who want a Whisper
    /// variant can switch in Settings → Models after onboarding.
    private var transcriptionModel: ParakeetModel { ModelCatalog.defaultParakeet }

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 14) {
            StepHeading(
                title: "Download a transcription model",
                detail: "Dictator needs at least one speech-to-text model on disk. We've picked a good default — you can switch later in Settings → Models."
            )

            ModelDownloadCard(
                title: transcriptionModel.displayName,
                subtitle: transcriptionModel.note,
                sizeMB: transcriptionModel.approxSizeMB,
                ramMB: transcriptionModel.approxRAMMB,
                state: manager.parakeetStates[transcriptionModel.id] ?? .unknown,
                primaryLabel: "Required",
                primaryStyle: .required,
                onDownload: {
                    manager.downloadParakeet(transcriptionModel.id, using: ParakeetServiceHolder.shared)
                },
                onCancel: {
                    manager.cancelParakeetDownload(transcriptionModel.id)
                }
            )
            .onAppear {
                // Make sure the active engine matches what the wizard
                // downloads — otherwise a user on a pre-existing install with
                // engine=whisper would download Parakeet but still try to
                // transcribe with Whisper afterwards.
                if s.settings.transcriptionEngine != .parakeet {
                    s.settings.transcriptionEngine = .parakeet
                    s.settings.parakeetModelID = transcriptionModel.id
                    state.save()
                }
            }

            LLMSection()

            Spacer(minLength: 0)

            Text("Downloads continue in the background — you can move on. The first dictation waits for the transcription model to finish.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { manager.refreshCachedStates() }
    }

}

private struct LLMSection: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared

    var body: some View {
        @Bindable var s = state
        // The "Recommended" pill points at whichever LLM fits this machine
        // (see ModelCatalog.recommendedLLMID). On lean Macs the recommended
        // option is *no* LLM, in which case the picker collapses to a
        // single No-LLM state — we don't want to dangle a button that
        // silently pulls 2 GB of weights onto an 8 GB machine.
        let recommendedID = ModelCatalog.recommendedLLMID
        let recommendedLLM: LLMModel? = ModelCatalog.llm(id: recommendedID)
        let llmDisabled = s.settings.llmModelID == ModelCatalog.noneLLMID
        let llmIsRecommended = s.settings.llmModelID == recommendedID && !llmDisabled
        let customLLM: LLMModel? = (!llmDisabled && !llmIsRecommended)
            ? ModelCatalog.llm(id: s.settings.llmModelID)
            : nil

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Formatting LLM (optional)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if recommendedLLM != nil {
                    Picker("", selection: Binding(
                        get: {
                            if llmDisabled { "none" }
                            else if customLLM != nil { "custom" }
                            else { "recommended" }
                        },
                        set: { newValue in
                            switch newValue {
                            case "none":        s.settings.llmModelID = ModelCatalog.noneLLMID
                            case "recommended": s.settings.llmModelID = recommendedID
                            default: break
                            }
                            state.save()
                        }
                    )) {
                        Text("No LLM").tag("none")
                        Text("Recommended").tag("recommended")
                        if customLLM != nil {
                            Text("Custom").tag("custom")
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: customLLM != nil ? 260 : 200)
                    .labelsHidden()
                }
            }

            if recommendedLLM == nil {
                // Lean machine: we won't even offer a one-click LLM download.
                // The user can still wire one up from Settings → Models, but
                // they have to opt in deliberately after seeing the cost.
                LeanLLMNotice()
            } else if llmDisabled {
                Text("Raw transcripts only. Fastest path — pick this if you're not sure or want to keep memory use low. You can add an LLM later from Settings → Models.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            } else if let custom = customLLM {
                ModelDownloadCard(
                    title: custom.displayName,
                    subtitle: "Already chosen in Settings → Models. Switch above to use the recommended model instead.",
                    sizeMB: custom.approxSizeMB,
                    ramMB: custom.approxRAMMB,
                    state: manager.llmStates[custom.id] ?? .unknown,
                    primaryLabel: "Custom",
                    primaryStyle: .optional,
                    onDownload: {
                        manager.downloadLLM(custom.id, using: LLMServiceHolder.shared)
                    },
                    onCancel: {
                        manager.cancelLLMDownload(custom.id)
                    }
                )
            } else if let llm = recommendedLLM {
                ModelDownloadCard(
                    title: llm.displayName,
                    subtitle: "Tidies punctuation, capitalisation, and structure after transcription.",
                    sizeMB: llm.approxSizeMB,
                    ramMB: llm.approxRAMMB,
                    state: manager.llmStates[llm.id] ?? .unknown,
                    primaryLabel: "Optional",
                    primaryStyle: .optional,
                    onDownload: {
                        manager.downloadLLM(llm.id, using: LLMServiceHolder.shared)
                    },
                    onCancel: {
                        manager.cancelLLMDownload(llm.id)
                    }
                )
            }
        }
    }
}

/// Shown in the wizard's LLM section when the user's Mac is on the tight
/// side — running an LLM alongside transcription would put the machine
/// into swap. The wording is honest about the tradeoff, and points at
/// Settings → Models for users who want to override anyway.
private struct LeanLLMNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22, height: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Mac has \(SystemMemory.totalGBLabel) of RAM — we recommend skipping the LLM.")
                    .font(.system(size: 13, weight: .semibold))
                Text("Running a language model alongside transcription would push memory use past what your Mac can comfortably handle. Dictator works fine without one — you'll get raw transcripts with the dictionary substitution applied. Settings → Models lets you add an LLM anyway if you accept the trade-off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

private enum ModelDownloadStyle {
    case required, optional
}

private struct ModelDownloadCard: View {
    let title: String
    let subtitle: String
    let sizeMB: Int
    /// Approximate resident RAM cost. Used to derive the fit chip so the
    /// user sees whether downloading this model is sensible on *their*
    /// machine before committing to multi-GB of weights.
    let ramMB: Int
    let state: ModelDownloadState
    let primaryLabel: String
    let primaryStyle: ModelDownloadStyle
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(badgeBackground)
                    .frame(width: 38, height: 38)
                Image(systemName: badgeIcon)
                    .foregroundStyle(badgeForeground)
                    .font(.system(size: 16, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(primaryLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(primaryStyle == .required ? Color.accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill((primaryStyle == .required ? Color.accentColor : Color.secondary).opacity(0.15))
                        )
                    FitChip(ramMB: ramMB)
                    Spacer()
                    Text(sizeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                progressOrAction
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var sizeLabel: String {
        sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB"
    }

    private var badgeIcon: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .downloading, .partial: "arrow.down.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "arrow.down.circle"
        }
    }

    private var badgeForeground: Color {
        switch state {
        case .ready: .green
        case .downloading, .partial: .accentColor
        case .failed: .orange
        default: .accentColor
        }
    }

    private var badgeBackground: Color {
        switch state {
        case .ready: Color.green.opacity(0.14)
        case .failed: Color.orange.opacity(0.14)
        default: Color.accentColor.opacity(0.14)
        }
    }

    @ViewBuilder private var progressOrAction: some View {
        switch state {
        case .ready:
            Text("Installed and ready.")
                .font(.callout)
                .foregroundStyle(.green)
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                HStack {
                    Text("Downloading… \(Int(p * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        case .partial(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                HStack {
                    Text("Paused at \(Int(p * 100))% — resume to finish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume", action: onDownload)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: onDownload)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        case .notDownloaded, .unknown:
            HStack {
                Spacer()
                Button("Download", action: onDownload)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Step 4: Ready

private struct ReadyStep: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeading(
                title: "You're set",
                detail: "Hold the hotkey, speak, release. Dictator transcribes and pastes into whichever app has focus."
            )

            HotkeyDisplay(
                label: "Dictate",
                description: "Hold to record. Release to transcribe and paste.",
                triggerMode: state.settings.triggerMode
            )

            HotkeyDisplay(
                label: "Assistant Mode",
                description: "Select text, hold the key, speak an instruction. The LLM rewrites or drafts a reply.",
                triggerMode: state.settings.assistantTriggerMode
            )

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text("Need to change anything?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Click the menu-bar icon → Settings to swap hotkeys, change models, add custom vocabulary, or tweak the formatting passes. You can reopen this guide any time from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HotkeyDisplay: View {
    let label: String
    let description: String
    let triggerMode: TriggerMode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "keyboard")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 16, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                    Text(triggerLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.secondary.opacity(0.18))
                        )
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var triggerLabel: String {
        switch triggerMode {
        case .keyboardShortcut: "Keyboard shortcut"
        case .leftOption:    "Left ⌥"
        case .rightOption:   "Right ⌥"
        case .leftCommand:   "Left ⌘"
        case .rightCommand:  "Right ⌘"
        case .leftControl:   "Left ⌃"
        case .rightControl:  "Right ⌃"
        case .leftShift:     "Left ⇧"
        case .rightShift:    "Right ⇧"
        case .fn:            "fn"
        }
    }
}
