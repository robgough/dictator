import Foundation
import Observation
import AVFoundation
import UIKit

/// Orchestrates the prototype's record → transcribe → display flow.
///
/// State stays deliberately small: a single `status` for the recording
/// lifecycle and a `transcript` string for the result. Model load
/// progress is tracked separately (`isModelLoading`) so the UI can show
/// a dedicated "Loading model…" indicator in the chrome rather than
/// blocking the mic button. There's no LLM pass chain, no pasteboard
/// injection back into a host app — that's all Phase 5+. Vocabulary
/// substitution from `VocabularyStore` is applied post-transcribe if
/// entries exist.
@MainActor
@Observable
final class RecordingViewModel {
    enum Status: Equatable {
        case idle
        /// Engine.start() returned but hasn't produced samples yet.
        case warmingUp
        case recording(level: Float)
        case transcribing
        case ready
        case error(String)

        /// True when the recorder is actively capturing. Drives the UI's
        /// "release to transcribe" affordance and the level meter visibility.
        var isCapturing: Bool {
            switch self {
            case .warmingUp, .recording: true
            default: false
            }
        }
    }

    enum Permission {
        case undetermined
        case granted
        case denied
    }

    /// Disk presence of the Parakeet model files. Independent of the
    /// in-memory `isModelLoaded` flag — a model can be on disk but not
    /// yet loaded into memory.
    enum ModelDiskStatus: Equatable {
        case checking
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var modelDiskStatus: ModelDiskStatus = .checking
    /// User-editable. Bound from `TextEditor` so the user can tweak the
    /// transcribed result before copying. The view model only writes it on
    /// transcribe-complete and on press-to-start (clearing the previous
    /// result); everything else is the user typing.
    var transcript: String = ""
    private(set) var permission: Permission

    /// True while a model prewarm task is in flight. Drives the header
    /// "Loading model…" pill. Distinct from the recording `status` so
    /// the user can see "I'm listening to you AND warming up the model
    /// in parallel" rather than the load blocking the recording UI.
    private(set) var isModelLoading: Bool = false
    /// True once `ensureLoaded` has returned successfully at least once
    /// for the active model. Used to decide whether to kick off a
    /// prewarm on subsequent presses (we don't — model stays resident).
    private(set) var isModelLoaded: Bool = false

    private let recorder = IOSAudioRecorder()
    private let parakeet = ParakeetService()
    /// User-chosen Parakeet variant. Read from UserDefaults at init so a
    /// preference set in a previous session survives relaunch. Mutated
    /// only via `selectModel(_:)` so the persisted value and the disk-
    /// status check stay in lockstep.
    private(set) var selectedModelID: String

    /// Strong handle on the in-flight prewarm so a quick press → release
    /// cycle reuses the same Task rather than racing two ensureLoaded
    /// calls. ParakeetService is `@MainActor`, so concurrent calls would
    /// serialise anyway, but doubling the work is wasteful.
    private var prewarmTask: Task<Void, Never>?

    /// Lightweight tactile feedback on press/release/result. Generators
    /// are held strongly so they're warm when the user taps — first-use
    /// initialisation otherwise produces a noticeable lag on the haptic.
    private let pressFeedback = UIImpactFeedbackGenerator(style: .light)
    private let resultFeedback = UINotificationFeedbackGenerator()

    init() {
        permission = Self.currentPermission()
        // Read the persisted model choice. `registerDefaults()` seeds v3
        // for first-launch users, so this is never empty in practice;
        // the `?? v3` fallback covers a hypothetical un-registered
        // launch path defensively.
        let storedID = UserDefaults.standard.string(forKey: DictatorIOSSettings.selectedModelKey)
            ?? "parakeet-tdt-0.6b-v3"
        selectedModelID = storedID
        // Cheap synchronous filesystem check — no network, no model
        // touched. Drives the first-launch UI: if the model isn't on
        // disk we show a download prompt instead of the recording UI.
        modelDiskStatus = ParakeetService.modelsExist(id: storedID) ? .downloaded : .notDownloaded
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording = self.status {
                self.status = .recording(level: level)
            } else if case .warmingUp = self.status {
                self.status = .recording(level: level)
            }
        }
        recorder.onReady = { [weak self] in
            guard let self else { return }
            if case .warmingUp = self.status {
                self.status = .recording(level: 0)
            }
        }
        recorder.onStartFailed = { [weak self] error in
            guard let self else { return }
            self.status = .error(error.localizedDescription)
        }
        pressFeedback.prepare()
        resultFeedback.prepare()
    }

    private static func currentPermission() -> Permission {
        switch IOSAudioRecorder.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Prompt for mic access if the user hasn't decided yet. Safe to call
    /// repeatedly; subsequent calls return the cached state without showing
    /// the system prompt again.
    func requestPermissionIfNeeded() async {
        guard permission == .undetermined else { return }
        let granted = await IOSAudioRecorder.requestRecordPermission()
        permission = granted ? .granted : .denied
    }

    /// Called when the user presses the mic button. No-op if the recorder
    /// is already engaged or we're mid-transcription — protects against a
    /// stuck "press is in progress" state when SwiftUI replays the press
    /// callback across view updates. Also no-ops if the model isn't on
    /// disk yet — the UI should already be presenting the download CTA
    /// in that state, but the guard is belt-and-braces.
    ///
    /// Also kicks off model prewarm in parallel with recording. Most of
    /// the load latency overlaps with the user actually speaking, so by
    /// the time they release the model is usually ready and `transcribe`
    /// is instant.
    func startRecording() {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        switch status {
        case .idle, .ready, .error:
            transcript = ""
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            recorder.start()
        default:
            // Already capturing or busy.
            return
        }
    }

    /// Stage the Parakeet model onto disk — explicit, with progress.
    /// Triggered by the first-launch CTA. Calls `parakeet.download`
    /// which writes the CoreML bundles into `ModelStorage.parakeetRoot()`
    /// but doesn't load them into memory; the model loads lazily on
    /// the first recording press, same as for users who already had
    /// the files locally.
    func downloadModel() async {
        guard case .notDownloaded = modelDiskStatus else { return }
        modelDiskStatus = .downloading(progress: 0)
        do {
            try await parakeet.download(modelID: selectedModelID) { [weak self] fraction in
                self?.modelDiskStatus = .downloading(progress: fraction)
            }
            modelDiskStatus = .downloaded
        } catch {
            modelDiskStatus = .failed(error.localizedDescription)
        }
    }

    /// Switch the active Parakeet variant. Persists the choice, swaps in
    /// the new disk-status (the new model may or may not be on disk),
    /// and unloads any currently-resident model so the next recording
    /// press warms up the right one. No-op if the caller asks for the
    /// model that's already selected — keeps the picker's onChange
    /// path idempotent.
    func selectModel(_ id: String) {
        guard id != selectedModelID else { return }
        // Belt-and-braces: refuse unknown IDs so a typo'd picker value
        // can't poison the persisted setting.
        guard ParakeetService.version(forID: id) != nil else { return }
        let previousID = selectedModelID
        UserDefaults.standard.set(id, forKey: DictatorIOSSettings.selectedModelKey)
        selectedModelID = id
        // Free the old model from memory — it's no longer the active
        // one. Files stay on disk; if the user switches back later
        // they get the cached download. `unload` is a no-op if the
        // previous model wasn't actually resident.
        parakeet.unload(modelID: previousID)
        isModelLoaded = false
        // Re-evaluate disk presence for the newly-selected variant so
        // the UI transitions to the download CTA when needed (and out
        // of it when the user picks a variant they already have).
        modelDiskStatus = ParakeetService.modelsExist(id: id) ? .downloaded : .notDownloaded
    }

    /// Retry path after a failed download — flips the state back to
    /// `.notDownloaded` so the CTA re-appears and the user can kick
    /// off another attempt.
    func resetDownload() {
        if case .failed = modelDiskStatus {
            modelDiskStatus = .notDownloaded
        }
    }

    /// Manually release the model from memory. Files stay on disk; the
    /// next recording press will reload them via the existing prewarm
    /// path. Used by the model status sheet to reclaim ~500 MB when
    /// the user knows they won't dictate for a while.
    func unloadModel() {
        parakeet.unload(modelID: selectedModelID)
        isModelLoaded = false
    }

    /// Idempotent: kicks off `ensureLoaded` if (and only if) we don't
    /// already have the model loaded and there's no prewarm in flight.
    /// Fire-and-forget — failures bubble up via `transcribe`'s error
    /// path with the user-visible message.
    private func prewarmModelIfNeeded() {
        guard !isModelLoaded, prewarmTask == nil else { return }
        isModelLoading = true
        prewarmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.parakeet.ensureLoaded(modelID: self.selectedModelID)
                self.isModelLoaded = true
            } catch {
                // Don't fail the recording — let stopRecording's
                // transcribe() retry and surface the real error there
                // with the proper UI affordance.
                NSLog("[DictatorIOS] Model prewarm failed: \(error.localizedDescription)")
            }
            self.isModelLoading = false
            self.prewarmTask = nil
        }
    }

    /// Called when the user releases the mic button. Drains the recorder,
    /// awaits the (possibly already-running) model load via transcribe's
    /// internal ensureLoaded, runs the samples through Parakeet, applies
    /// vocabulary substitution, and persists to history.
    func stopRecording() async {
        guard status.isCapturing else { return }
        let samples = recorder.stop()
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            return
        }

        status = .transcribing

        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            // SpokenCues handles all the deterministic substitutions —
            // punctuation/number/time/currency/emoji passes that the
            // macOS app runs out of the box. Then Vocabulary runs LAST
            // so a user's custom entry can override anything SpokenCues
            // produced (e.g. mapping "fire emoji" to a wildfire alert
            // text instead of 🔥). tidyDelivery cleans up the stray
            // soft punctuation Whisper sometimes leaves around emojis.
            var processed = SpokenCues.apply(to: raw, options: DictatorIOSSettings.cueOptions)
            processed = Vocabulary.apply(VocabularyStore.shared.entries, to: processed)
            processed = SpokenCues.tidyDelivery(processed)

            // Optional Apple-Intelligence-backed filler-word cleanup.
            // Runs AFTER deterministic substitutions so the LLM sees
            // the cue-resolved text (no "comma" lingering as filler).
            // Failures swallow silently — the user already has a
            // working transcript and we don't want to error out the
            // whole recording over a cleanup hiccup.
            if UserDefaults.standard.bool(forKey: DictatorIOSSettings.foundationCleanupKey) {
                do {
                    processed = try await AppleFoundationCleanup.tidy(processed)
                } catch {
                    NSLog("[DictatorIOS] Foundation cleanup skipped: \(error.localizedDescription)")
                }
            }

            transcript = processed
            // Keep the raw Parakeet text alongside the polished delivery
            // so the history detail can show "what I actually heard"
            // when the user wants to recover something the cleanup
            // pass smoothed over.
            DictationHistoryStore.shared.append(processed, raw: raw)
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
        }
    }

    /// One-tap clipboard copy. The mainstream "navigate to your destination
    /// then long-press → paste" flow is the prototype's substitute for the
    /// (not-yet-built) keyboard extension.
    func copyTranscriptToClipboard() {
        guard !transcript.isEmpty else { return }
        UIPasteboard.general.string = transcript
        resultFeedback.notificationOccurred(.success)
    }
}
