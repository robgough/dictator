import SwiftUI
import UIKit
@preconcurrency import AVFoundation

/// First-launch walkthrough that sequences the four bits of system
/// setup Dictator needs before it can actually work end-to-end:
///   1. Microphone permission
///   2. Parakeet model download (~500 MB)
///   3. Keyboard extension installed via system Settings
///   4. Open Access granted to the keyboard
///
/// Steps render as a vertical checklist with `pending` / `inProgress`
/// / `done` states. The single bottom CTA is always wired to the
/// active (first non-done) step, so the user has one button to focus
/// on at a time. A "Skip for now" affordance in the top-left lets
/// them dismiss and configure later from the existing scattered
/// cards.
///
/// State detection is best-effort and asymmetric:
///   - Mic permission and model presence have direct APIs.
///   - Keyboard installed: probed via `UITextInputMode.activeInputModes`
///     using the keyboard's bundle identifier as the primary signal,
///     with a "I've installed it" confirmation as a fallback for
///     when the host hasn't been re-foregrounded yet.
///   - Open Access: no direct API. The cleanest indirect signal is a
///     prior keyboard handshake recorded in the App Group (request,
///     host-state, or readiness write from the keyboard's side); if
///     the user gets that far we know Open Access was on at some
///     point. Otherwise, "I've enabled it" confirmation.
///
/// Once step 4 flips to done — either automatically or via the
/// confirmation tap — the sheet auto-dismisses and writes the
/// `onboardingCompletedKey` flag so it never re-presents.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Pass-through so the sheet can read live model status without
    /// duplicating the view model's disk-check and download logic.
    /// Also lets the "Download model" CTA kick off the same task the
    /// inline `downloadPrompt` would. Plain stored property —
    /// `RecordingViewModel` is `@Observable`, so SwiftUI re-runs the
    /// body when any read property changes; no `@Bindable` needed
    /// since we never produce a binding from it here.
    let viewModel: RecordingViewModel

    /// Mirrors the persisted "onboarding done" flag. Flipped by both
    /// the natural completion path (step 4 → done) and the Skip button.
    @AppStorage(DictatorIOSSettings.onboardingCompletedKey) private var onboardingCompleted = false
    /// Mirrors the older keyboard-card flag so completing the sheet
    /// also hides that card (the sheet supersedes it).
    @AppStorage(DictatorIOSSettings.keyboardOnboardingDismissedKey) private var keyboardOnboardingDismissed = false

    /// Latches once the user taps "I've installed it" on step 3, in
    /// case the active-input-modes probe is unreliable. Resets only
    /// if the user re-launches without onboarding having completed,
    /// which is fine — they're walked through the same steps again.
    @State private var keyboardInstallConfirmed = false
    /// Same idea for step 4 — latches the "I've enabled Open Access"
    /// confirmation so the user can advance past a step we can't
    /// detect with certainty.
    @State private var openAccessConfirmed = false

    /// Re-evaluated whenever the scene foregrounds — the user
    /// flipping a system Settings switch is invisible to us until we
    /// come back, so we recheck the keyboard-install probe on return.
    @State private var refreshTick = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        VStack(spacing: 12) {
                            ForEach(steps.indices, id: \.self) { idx in
                                stepRow(step: steps[idx], index: idx)
                            }
                        }
                    }
                    .padding(20)
                }

                bottomCTA
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .padding(.top, 8)
                    .background(
                        Color(.systemBackground)
                            .ignoresSafeArea(edges: .bottom)
                    )
            }
            .navigationTitle("Set up Dictator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip for now") {
                        // Match the "Done" path — flip both flags so
                        // neither this sheet nor the keyboard card
                        // ambushes the user after they've explicitly
                        // chosen to skip.
                        onboardingCompleted = true
                        keyboardOnboardingDismissed = true
                        dismiss()
                    }
                    .font(.body)
                }
            }
            .onChange(of: scenePhase) { _, new in
                // The user is sent into iOS Settings for steps 3 and
                // 4; flipping a switch there doesn't notify us, so
                // forcing a recompute on every foreground means the
                // checklist updates the moment they come back.
                if new == .active { refreshTick &+= 1 }
            }
            .onChange(of: allStepsDone) { _, done in
                // Auto-dismiss the instant step 4 completes — leaving
                // the user staring at a fully-checked list with a
                // "Done" button is the easy path but the abrupt
                // dismissal reads as "the app finished setting itself
                // up", which is what we want here.
                if done {
                    onboardingCompleted = true
                    keyboardOnboardingDismissed = true
                    dismiss()
                }
            }
            .interactiveDismissDisabled(true)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)
            Text("A few quick steps")
                .font(.title2.weight(.semibold))
            Text("Dictator runs entirely on this device. Walk through these four steps to get set up — most of it is one-time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Steps model

    /// Concrete state of a single onboarding row. `pending` rows are
    /// rendered greyed-out and don't respond to taps; `inProgress` is
    /// the only row whose tap fires the action (matched by the bottom
    /// CTA); `done` is checked off.
    private enum StepState { case pending, inProgress, done }

    /// Static per-row config. The state is computed at render time
    /// from live signals — we don't carry it in the model so the
    /// truth always reflects the actual system state.
    private struct Step {
        let kind: Kind
        let title: String
        let body: String
        let ctaWhenActive: String

        enum Kind { case microphone, model, keyboard, openAccess }
    }

    private let steps: [Step] = [
        Step(
            kind: .microphone,
            title: "Grant microphone access",
            body: "Dictator can't transcribe without it. iOS will ask once, then remember.",
            ctaWhenActive: "Grant microphone access"
        ),
        Step(
            kind: .model,
            title: "Download the speech model",
            body: "Parakeet, around 460 MB. Runs on-device — no audio leaves your device. You can leave the app while it downloads; it'll pick up where it left off if your connection drops.",
            ctaWhenActive: "Download model"
        ),
        Step(
            kind: .keyboard,
            title: "Install the Dictator keyboard",
            body: "In Settings: General → Keyboard → Keyboards → Add New Keyboard → Dictator.",
            ctaWhenActive: "Open Settings"
        ),
        Step(
            kind: .openAccess,
            title: "Allow Full Access for the keyboard",
            body: "Settings → General → Keyboard → Keyboards → Dictator → Allow Full Access. Required so the keyboard can talk to Dictator.",
            ctaWhenActive: "Open Settings"
        ),
    ]

    // MARK: - State resolution

    /// `refreshTick` is read once here so SwiftUI sees a dependency
    /// and re-runs the body when scene-phase changes bump it. Without
    /// the read the change wouldn't propagate.
    private func state(for kind: Step.Kind) -> StepState {
        _ = refreshTick
        switch kind {
        case .microphone:
            return micGranted ? .done : (firstPendingKind == .microphone ? .inProgress : .pending)
        case .model:
            return modelDownloaded ? .done : (firstPendingKind == .model ? .inProgress : .pending)
        case .keyboard:
            return keyboardInstalled ? .done : (firstPendingKind == .keyboard ? .inProgress : .pending)
        case .openAccess:
            return openAccessGranted ? .done : (firstPendingKind == .openAccess ? .inProgress : .pending)
        }
    }

    /// The first kind not yet done — drives both the inline
    /// "in progress" badge on the matching row and the bottom CTA.
    /// Nil when every step is complete.
    private var firstPendingKind: Step.Kind? {
        if !micGranted { return .microphone }
        if !modelDownloaded { return .model }
        if !keyboardInstalled { return .keyboard }
        if !openAccessGranted { return .openAccess }
        return nil
    }

    private var allStepsDone: Bool { firstPendingKind == nil }

    // MARK: - Direct + indirect signals

    private var micGranted: Bool {
        IOSAudioRecorder.recordPermission == .granted
    }

    private var modelDownloaded: Bool {
        // Matches the same disk check the view model uses on init —
        // pure filesystem probe, no model touched.
        ParakeetService.modelsExist(id: viewModel.selectedModelID)
    }

    /// Probe iOS's installed input modes for the Dictator keyboard's
    /// bundle ID. Active input modes are only populated once the user
    /// has added the keyboard via Settings. The bundle-ID match is
    /// the load-bearing bit; checking the localised display name
    /// would be fragile across iOS UI changes.
    private var keyboardInstalled: Bool {
        if keyboardInstallConfirmed { return true }
        _ = refreshTick
        let keyboardBundleID = "net.robgough.DictatorIOS.Keyboard"
        return UITextInputMode.activeInputModes.contains { mode in
            // `primaryLanguage` is not the right field; the bundle
            // identifier is exposed via the private `identifier`
            // property — which we can't safely depend on — so we
            // fall back to a coarser signal: the input mode's
            // value(forKey:) using "identifier", which is what UIKit
            // uses internally. If it returns nil on a future iOS
            // we just lean on the confirmation fallback.
            if let id = mode.value(forKey: "identifier") as? String {
                return id.contains(keyboardBundleID)
            }
            return false
        }
    }

    /// Open Access is impossible to query directly. The cleanest
    /// indirect signal: the keyboard extension has written *something*
    /// to the App Group container, which is only possible with Full
    /// Access turned on. We check for any of the three writes the
    /// keyboard makes — a pending request, a host-state heartbeat
    /// from a prior session, or a stop request — and treat any of
    /// them as proof the access was granted. Otherwise we wait for
    /// the user to confirm via the inline button.
    private var openAccessGranted: Bool {
        if openAccessConfirmed { return true }
        _ = refreshTick
        guard let defaults = UserDefaults(suiteName: KeyboardBridge.appGroupID) else { return false }
        // Any of these means the keyboard has successfully written
        // to the shared container at least once.
        if defaults.data(forKey: "DictatorKeyboard.request") != nil { return true }
        if defaults.data(forKey: "DictatorKeyboard.hostState") != nil { return true }
        if defaults.string(forKey: "DictatorKeyboard.stopRequest") != nil { return true }
        return false
    }

    // MARK: - Row + CTA

    @ViewBuilder
    private func stepRow(step: Step, index: Int) -> some View {
        let s = state(for: step.kind)
        let isActive = s == .inProgress
        HStack(alignment: .top, spacing: 14) {
            stateBadge(state: s, number: index + 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(s == .pending ? .secondary : .primary)
                Text(step.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isActive, needsInlineConfirmButton(for: step.kind) {
                    Button {
                        confirmTap(for: step.kind)
                    } label: {
                        Text(inlineConfirmTitle(for: step.kind))
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .opacity(s == .done ? 0.55 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Only the active row is interactive — taps on pending
            // rows would pre-empt the linear flow, and taps on done
            // rows have nothing useful to do.
            guard isActive else { return }
            performAction(for: step.kind)
        }
    }

    /// 26 pt badge — green check on done, accent number on active,
    /// muted number on pending. Same visual vocabulary as the existing
    /// `KeyboardSetupSheet` for consistency.
    @ViewBuilder
    private func stateBadge(state: StepState, number: Int) -> some View {
        switch state {
        case .done:
            ZStack {
                Circle().fill(.green)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
        case .inProgress:
            ZStack {
                Circle().fill(.tint)
                Text("\(number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
        case .pending:
            ZStack {
                Circle().fill(Color(.tertiarySystemFill))
                Text("\(number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 26, height: 26)
        }
    }

    /// Steps 3 and 4 have no fire-and-forget completion path, so the
    /// active row gets a secondary inline button for the user to
    /// signal "I've done it" once they're back from Settings. Steps
    /// 1 and 2 finish naturally via the system prompt or download
    /// callback, so no confirmation button.
    private func needsInlineConfirmButton(for kind: Step.Kind) -> Bool {
        switch kind {
        case .keyboard: return !keyboardInstallConfirmed && !keyboardInstalledViaProbe
        case .openAccess: return !openAccessConfirmed && !openAccessGrantedViaProbe
        default: return false
        }
    }

    /// Bare probe-only signals — without the `*Confirmed` latches —
    /// so the inline confirmation button only shows when the
    /// detector hasn't already lit the row up green.
    private var keyboardInstalledViaProbe: Bool {
        _ = refreshTick
        let keyboardBundleID = "net.robgough.DictatorIOS.Keyboard"
        return UITextInputMode.activeInputModes.contains { mode in
            if let id = mode.value(forKey: "identifier") as? String {
                return id.contains(keyboardBundleID)
            }
            return false
        }
    }

    private var openAccessGrantedViaProbe: Bool {
        _ = refreshTick
        guard let defaults = UserDefaults(suiteName: KeyboardBridge.appGroupID) else { return false }
        if defaults.data(forKey: "DictatorKeyboard.request") != nil { return true }
        if defaults.data(forKey: "DictatorKeyboard.hostState") != nil { return true }
        if defaults.string(forKey: "DictatorKeyboard.stopRequest") != nil { return true }
        return false
    }

    private func inlineConfirmTitle(for kind: Step.Kind) -> String {
        switch kind {
        case .keyboard: return "I've added it"
        case .openAccess: return "I've enabled it"
        default: return ""
        }
    }

    private func confirmTap(for kind: Step.Kind) {
        switch kind {
        case .keyboard: keyboardInstallConfirmed = true
        case .openAccess: openAccessConfirmed = true
        default: break
        }
    }

    /// Bottom CTA — single source of truth for "what should the user
    /// do next". Title changes with the active step; tap dispatches
    /// to the same `performAction` the row tap uses.
    @ViewBuilder
    private var bottomCTA: some View {
        if let active = firstPendingKind, let step = steps.first(where: { $0.kind == active }) {
            Button {
                performAction(for: active)
            } label: {
                Group {
                    if isBusy(for: active) {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(busyTitle(for: active))
                        }
                    } else {
                        Text(step.ctaWhenActive)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy(for: active))
        } else {
            Button {
                onboardingCompleted = true
                keyboardOnboardingDismissed = true
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Reflects in-flight system work — currently only the model
    /// download has an observable "running" state. Mic permission
    /// fires off a system alert; keyboard / open-access deep-link
    /// out into Settings and there's no spinner-worthy state to show.
    private func isBusy(for kind: Step.Kind) -> Bool {
        switch kind {
        case .model:
            switch viewModel.modelDiskStatus {
            case .downloading, .paused: return true
            default: return false
            }
        default: return false
        }
    }

    private func busyTitle(for kind: Step.Kind) -> String {
        switch kind {
        case .model:
            if case .downloading(let p, _) = viewModel.modelDiskStatus {
                return "Downloading… \(Int(p * 100))%"
            }
            if case .paused = viewModel.modelDiskStatus {
                return "Paused"
            }
            return "Downloading…"
        default: return ""
        }
    }

    // MARK: - Actions

    private func performAction(for kind: Step.Kind) {
        switch kind {
        case .microphone:
            Task { await viewModel.requestPermissionIfNeeded() }
        case .model:
            // Mirrors the inline download CTA. The view model guards
            // against double-kick: if a download is already in flight
            // this is a no-op, which matches the disabled-state on
            // the button.
            Task { await viewModel.downloadModel() }
        case .keyboard, .openAccess:
            // Same destination for both — iOS doesn't expose deep-
            // links to the Keyboards screen specifically, so this
            // lands the user on the per-app Settings page from
            // which both Add-New-Keyboard and Allow-Full-Access are
            // a few taps away. The walkthrough body text spells out
            // the path.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}
