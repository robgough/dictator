import SwiftUI
import UIKit
@preconcurrency import AVFoundation

/// First-launch walkthrough that sequences the five bits of system
/// setup Dictator needs before it can actually work end-to-end:
///   1. Microphone permission
///   2. Pick the Parakeet variant (multilingual v3 default, or English-only v2)
///   3. Parakeet model download (~460 MB)
///   4. Keyboard extension installed via system Settings
///   5. Open Access granted to the keyboard
///
/// Steps render as a vertical checklist with `pending` / `inProgress`
/// / `done` states. The single bottom CTA is always wired to the
/// active (first non-done) step, so the user has one button to focus
/// on at a time. A "Skip for now" affordance in the top-left lets
/// them dismiss and configure later from the existing scattered
/// cards. If the user skips before step 2, the persisted
/// `selectedModelID` stays at whatever `UserDefaults` returns — the
/// app seeds v3 in `registerDefaults`, so the skip path is safe and
/// the user can change it later from the model picker on the
/// download screen / settings.
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
    /// Same idea for step 5 — latches the "I've enabled Open Access"
    /// confirmation so the user can advance past a step we can't
    /// detect with certainty.
    @State private var openAccessConfirmed = false

    /// Latches the model-picker step (step 2) once the user explicitly
    /// confirms their choice. Persisted via `@AppStorage` so a
    /// kill-and-relaunch mid-onboarding doesn't bounce the user back
    /// to the picker — if they've already chosen a model and started
    /// the (background, resumable) download, the relaunched onboarding
    /// sheet lands them directly on the download step with the
    /// resumed progress visible. Returning users with the model
    /// already on disk also bypass via the `chooseModel` state check.
    @AppStorage(DictatorIOSSettings.modelChoiceConfirmedKey) private var modelChoiceConfirmed = false

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
            Text("Dictator runs entirely on this device. Walk through these steps to get set up — most of it is one-time.")
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

        enum Kind { case microphone, chooseModel, model, keyboard, openAccess }
    }

    private let steps: [Step] = [
        Step(
            kind: .microphone,
            title: "Grant microphone access",
            body: "Dictator can't transcribe without it. iOS will ask once, then remember.",
            ctaWhenActive: "Grant microphone access"
        ),
        Step(
            kind: .chooseModel,
            title: "Choose your language model",
            // Body intentionally short — the per-variant detail copy
            // lives inside the inline picker rows below, where the user
            // is actually making the decision.
            body: "Multilingual covers most users; English-only is a touch leaner if you'll never dictate in another language.",
            ctaWhenActive: "Continue"
        ),
        Step(
            kind: .model,
            title: "Download the speech model",
            // Size is approximate and the same for both variants — the
            // raw download is similar, the difference is what's *inside*
            // the weights. Keeping the copy variant-agnostic avoids the
            // body text contradicting whichever picker option was chosen
            // on the previous step.
            body: "Around 460 MB. Runs on-device — no audio leaves your device. You can leave the app while it downloads; it'll pick up where it left off if your connection drops.",
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
        case .chooseModel:
            return modelChoiceMade ? .done : (firstPendingKind == .chooseModel ? .inProgress : .pending)
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
        if !modelChoiceMade { return .chooseModel }
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

    /// Treat the language-model choice as already made when either:
    ///   - the user explicitly tapped Continue in this session
    ///     (`modelChoiceConfirmed`), OR
    ///   - the currently-selected variant is already on disk —
    ///     proof that a previous session committed to that choice and
    ///     downloaded against it. Re-prompting a returning user for a
    ///     decision they've effectively already locked in would be
    ///     noise.
    /// The persisted default is v3 (seeded by `registerDefaults`), so
    /// a brand-new user lands on this step with v3 pre-selected; they
    /// still have to confirm to advance the checklist.
    private var modelChoiceMade: Bool {
        if modelChoiceConfirmed { return true }
        return ParakeetService.modelsExist(id: viewModel.selectedModelID)
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
                // The language-model choice is made via two tappable
                // option cards rather than a segmented picker — the
                // copy-per-option doesn't fit comfortably under a
                // narrow segment and the user benefits from seeing
                // both tradeoffs side by side before committing.
                if isActive, step.kind == .chooseModel {
                    modelChoiceInline
                }
                // Done-state summary for the model-choice row. Shows
                // which variant landed plus a pointer to Settings,
                // and — if the download hasn't started yet — a
                // "Change" affordance that re-opens the picker.
                if s == .done, step.kind == .chooseModel {
                    modelChoiceDoneSummary
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
            // Done-state model-choice row stays interactive — the user
            // can still change their mind right up to the moment the
            // download starts (i.e. while step 3 is pending, not yet
            // downloading). After the download begins, the choice is
            // locked in: switching variants mid-flight would invalidate
            // the partial bytes on disk.
            if s == .done, step.kind == .chooseModel, modelChoiceIsReopenable {
                modelChoiceConfirmed = false
                return
            }
            // Only the active row is otherwise interactive — taps on
            // pending rows would pre-empt the linear flow, and taps on
            // done rows have nothing useful to do.
            guard isActive else { return }
            // Several steps host their own inline button instead of
            // relying on the row chrome being the tap target:
            //   - `.chooseModel` has the picker cards + bottom CTA
            //   - `.model` has an explicit "Start download" / pause /
            //     try-again button inline, so a casual row tap mustn't
            //     silently kick off a 460 MB download.
            // For both, the row tap is intentionally a no-op so the
            // user has to use the explicit affordance.
            if step.kind == .chooseModel || step.kind == .model { return }
            performAction(for: step.kind)
        }
    }

    /// True while the user can still go back to the picker — i.e.
    /// before any download bytes have landed. Once the downloader
    /// transitions into `.downloading` / `.paused` / `.downloaded` we
    /// lock the choice in (and the Settings model picker is the
    /// post-onboarding escape hatch).
    private var modelChoiceIsReopenable: Bool {
        switch viewModel.modelDiskStatus {
        case .notDownloaded, .checking, .failed:
            return true
        case .downloading, .paused, .downloaded:
            return false
        }
    }

    /// Done-state summary for the `chooseModel` row. Names the chosen
    /// variant, hints at the Settings escape hatch for later changes,
    /// and surfaces a "Change" affordance while the download hasn't
    /// started yet.
    @ViewBuilder
    private var modelChoiceDoneSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Selected: \(Self.modelDisplayName(for: viewModel.selectedModelID))")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            if modelChoiceIsReopenable {
                Text("Tap to change, or update later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Locked in for this download. Change later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private static func modelDisplayName(for id: String) -> String {
        switch id {
        case "parakeet-tdt-0.6b-v3": return "Parakeet (multilingual)"
        case "parakeet-tdt-0.6b-v2": return "Parakeet (English-only)"
        default: return id
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

    /// True when the model row's inline state already presents an
    /// actionable affordance, so the bottom CTA should retract rather
    /// than duplicate it. Now covers every state the user can hit on
    /// step 3 — including `.notDownloaded` / `.checking`, where the
    /// row hosts an explicit "Start download" button instead of the
    /// old "tap anywhere on the card" implicit kick-off.
    private var hidesBottomCTAForModel: Bool {
        // All downloadable states have an inline button somewhere on
        // the row, so the bottom CTA would just be a duplicate.
        switch viewModel.modelDiskStatus {
        case .notDownloaded, .checking, .downloading, .paused, .failed:
            return true
        case .downloaded:
            return false
        }
    }

    /// Two-option picker rendered inside the active `chooseModel` row.
    /// Each option is a tappable card that flips `viewModel.selectedModelID`
    /// via the existing `selectModel(_:)` API — the user is free to
    /// switch back and forth before tapping the bottom CTA to lock it
    /// in. Selecting a variant the user already has on disk is fine —
    /// `selectModel` re-evaluates `modelDiskStatus`, so committing on
    /// that path lands the user directly on the keyboard-install step
    /// (the download step's check goes green immediately).
    @ViewBuilder
    private var modelChoiceInline: some View {
        // Order the cards so the locale-recommended variant sits first
        // (and carries the "Recommended" badge in its detail copy).
        // English-locale phones get v2 on top; everyone else gets v3.
        let recommendedID = DictatorIOSSettings.recommendedModelID()
        let v3Card = ModelOption(
            id: "parakeet-tdt-0.6b-v3",
            title: "Parakeet (multilingual)",
            base: "Around 460 MB. Supports English plus French, German, Spanish, Italian, Dutch, and other European languages."
        )
        let v2Card = ModelOption(
            id: "parakeet-tdt-0.6b-v2",
            title: "Parakeet (English-only)",
            base: "Around 460 MB. Same speed, slightly tighter on English accuracy because the model isn't splitting capacity across other languages."
        )
        let ordered: [ModelOption] = (recommendedID == v2Card.id) ? [v2Card, v3Card] : [v3Card, v2Card]
        VStack(spacing: 8) {
            ForEach(ordered, id: \.id) { card in
                modelOptionCard(
                    id: card.id,
                    title: card.title,
                    detail: (card.id == recommendedID ? "Recommended. " : "") + card.base
                )
            }
        }
        .padding(.top, 6)
    }

    /// Lightweight tuple used only inside `modelChoiceInline` to
    /// describe a picker card before its "Recommended. " prefix is
    /// stamped on at render time.
    private struct ModelOption {
        let id: String
        let title: String
        let base: String
    }

    /// One row in the picker. Tappable surface mutates `selectedModelID`
    /// via the view model; the checkmark + accent border tracks the
    /// current selection without latching anything until the user hits
    /// the bottom CTA.
    @ViewBuilder
    private func modelOptionCard(id: String, title: String, detail: String) -> some View {
        let selected = viewModel.selectedModelID == id
        Button {
            viewModel.selectModel(id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        case .notDownloaded, .checking:
            // Explicit "Start download" button so it's obvious what's
            // about to happen. Previously the card itself was the tap
            // target — kicking off a 460 MB download from a casual
            // row tap read as opaque ("did I just trigger something?").
            // The bottom CTA also hides for this state so there's a
            // single, prominent affordance right on the row.
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await viewModel.confirmAndDownloadModel() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Start download")
                    }
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                Text("Around 460 MB. You can leave the app once the download starts — it'll keep going in the background.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
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
        case .chooseModel:
            // The picker rows have already mutated `viewModel.selectedModelID`
            // via `selectModel` at the moment of tap; the bottom CTA is
            // a pure "lock it in" affordance. Latching `modelChoiceConfirmed`
            // flips `modelChoiceMade` to true, which advances
            // `firstPendingKind` to `.model` on the next render.
            modelChoiceConfirmed = true
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
