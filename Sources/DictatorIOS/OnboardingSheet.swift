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
    /// inline download prompt would. `@Bindable` so the cellular-
    /// confirmation alert below can bind `$viewModel.cellularConfirmationPending`
    /// — without the projection the alert can't toggle the flag back to
    /// false through `$viewModel`.
    @Bindable var viewModel: RecordingViewModel

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
            // Cellular guard, mirrored from ContentView. Before this, the
            // sheet's "Download model" CTA was calling `downloadModel()`
            // directly — bypassing the cellular check entirely. Now it
            // routes through `confirmAndDownloadModel()`, which flips
            // `cellularConfirmationPending` on a metered link and lets
            // the alert here pick up the question. Without this attached
            // to the sheet (and not just to ContentView underneath), the
            // user on cellular saw absolutely nothing happen when they
            // tapped the button.
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
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("AboutLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                // Inline model-download state lives ON the row so the
                // user gets real feedback (progress bar, MB readout,
                // transfer rate, file count, pause / cancel) without
                // the bottom CTA's single-line "Downloading… X%" being
                // the only signal something is happening.
                if isActive, step.kind == .model {
                    modelInlineStatus
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
    ///
    /// Hidden while the model step is downloading, paused, or just
    /// failed — the inline UI on the row carries the affordance in
    /// those states, and a second progress indicator down here was
    /// just noise. Reappears once the next step takes over.
    @ViewBuilder
    private var bottomCTA: some View {
        if let active = firstPendingKind, let step = steps.first(where: { $0.kind == active }) {
            if active == .model, hidesBottomCTAForModel {
                EmptyView()
            } else {
                Button {
                    performAction(for: active)
                } label: {
                    Text(step.ctaWhenActive)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
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

    /// True when the model row's inline state — downloading, paused,
    /// or just failed — already presents an actionable affordance, so
    /// the bottom CTA should retract rather than duplicate it.
    private var hidesBottomCTAForModel: Bool {
        switch viewModel.modelDiskStatus {
        case .downloading, .paused, .failed: return true
        default: return false
        }
    }

    /// Inline progress / failure block rendered inside the active model
    /// step row. Visually mirrors ContentView's full-screen `downloadingView`
    /// but at a smaller scale — the row is a callout card inside a list,
    /// not a takeover screen. Uses the rich `BackgroundModelDownloader.Progress`
    /// snapshot the view model surfaces (bytes downloaded / total,
    /// transfer rate, file count) plus pause / resume / cancel buttons.
    @ViewBuilder
    private var modelInlineStatus: some View {
        switch viewModel.modelDiskStatus {
        case .downloading(_, let snapshot):
            downloadingInlineBlock(snapshot: snapshot, paused: false, pausedReason: nil)
        case .paused(let snapshot, let reason):
            downloadingInlineBlock(snapshot: snapshot, paused: true, pausedReason: reason)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your progress so far is saved. Tap Try again to resume from where you left off.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await viewModel.confirmAndDownloadModel() }
                } label: {
                    Text("Try again")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 6)
        default:
            EmptyView()
        }
    }

    /// Shared renderer for downloading + paused states. Mirrors
    /// ContentView's `downloadingView` design — same byte / rate / file
    /// formatting, same pause/resume/cancel button row, same
    /// "you can leave the app" reassurance — at smaller font sizes so
    /// it sits comfortably inside a step row.
    @ViewBuilder
    private func downloadingInlineBlock(
        snapshot: BackgroundModelDownloader.Progress,
        paused: Bool,
        pausedReason: String?
    ) -> some View {
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

        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: max(0, min(1, snapshot.fraction)))
                .progressViewStyle(.linear)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(percent)%  ·  \(downloaded) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let rate {
                    Text(rate)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if snapshot.totalFiles > 0 {
                    Text("File \(min(snapshot.currentFileIndex + 1, snapshot.totalFiles)) of \(snapshot.totalFiles)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Text(paused
                 ? "Tap Resume to continue where you left off."
                 : "You can leave the app — the download keeps running in the background. Come back any time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let pausedReason {
                Text(pausedReason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if paused {
                    Button {
                        Task { await viewModel.downloadModel() }
                    } label: {
                        Text("Resume").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await viewModel.pauseDownload() }
                    } label: {
                        Text("Pause").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button(role: .destructive) {
                    Task { await viewModel.cancelDownload() }
                } label: {
                    Text("Cancel").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func performAction(for kind: Step.Kind) {
        switch kind {
        case .microphone:
            Task { await viewModel.requestPermissionIfNeeded() }
        case .model:
            // Routes through the cellular-aware entry point so a user on
            // metered data gets the confirmation alert before the 460 MB
            // download starts. On Wi-Fi this falls straight through to
            // `downloadModel()`. The view model guards against double-
            // kick: if a download is already in flight the call is a
            // no-op, which matches the inline-progress UI taking over
            // the row.
            Task { await viewModel.confirmAndDownloadModel() }
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
