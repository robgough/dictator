import Foundation
import Observation
import AVFoundation
import Network
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

    /// Tracks which physical button kicked off the current recording.
    /// `.dictation` is the red mic — output replaces the transcript.
    /// `.assist` is the purple wand — output is fed back into
    /// `AppleFoundationAssist.transform(text:instruction:)` as the
    /// INSTRUCTION applied to the current transcript.
    enum RecordingMode: Equatable {
        case dictation
        case assist
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
    /// Which button is driving the current capture. Defaults to
    /// dictation; set by `startRecording` / `startAssistRecording` at
    /// the moment of press. The UI uses this to render the level ring
    /// around the active button only.
    private(set) var recordingMode: RecordingMode = .dictation

    /// Set when the host has been launched by the keyboard extension
    /// for a single-shot dictation. The next successful transcript
    /// is written to `KeyboardBridge` so the keyboard can insert it
    /// when the user returns to the original app, then cleared.
    /// `nil` for normal in-app use.
    var activeKeyboardSession: UUID?

    /// True when we're driving a keyboard-extension flow. Switches
    /// the UI to a tap-to-stop button and a "switch back to your app"
    /// affordance instead of the press-and-hold + Copy pairing.
    var isKeyboardMode: Bool { activeKeyboardSession != nil }
    /// User-editable. Bound from `TextEditor` so the user can tweak the
    /// transcribed result before copying. The view model only writes it on
    /// transcribe-complete and on press-to-start (clearing the previous
    /// result); everything else is the user typing.
    var transcript: String = ""
    /// One-step undo target. Snapshotted at the start of each
    /// dictation or assist press — i.e. just before a programmatic
    /// overwrite of `transcript`. The undo button toggles current /
    /// previous, so a second tap acts as redo.
    private(set) var previousTranscript: String?
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

    /// Drives the cellular-download confirmation alert in `ContentView`.
    /// Set by `confirmAndDownloadModel()` when it detects the device is
    /// on cellular (or the path is unknown) so we don't blindside the
    /// user with a ~460 MB download against their data plan. The view
    /// flips this back to false via the alert's button actions; the
    /// "Download anyway" path calls `downloadModel()` directly.
    var cellularConfirmationPending: Bool = false

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

    /// Polls `KeyboardBridge.consumeStopRequest` while a
    /// keyboard-driven recording is in flight, so the user can stop
    /// from the keyboard after switching back to the original app.
    /// Cancelled in the cleanup path after `stopRecording`.
    private var stopWatcherTask: Task<Void, Never>?

    /// Periodic 3-second tick that re-stamps `updatedAt` on the host
    /// state during long transcriptions (or any phase that doesn't
    /// naturally produce its own updates). Keyboard side uses the
    /// timestamp to detect a dead host — without this, transcripts
    /// longer than the keyboard's staleness window would falsely
    /// register as "host crashed".
    private var heartbeatTask: Task<Void, Never>?

    /// Throttled timestamp of the last host-state write — keeps the
    /// `onLevel` callback from hammering UserDefaults at the audio
    /// buffer rate (~20 Hz). Caps writes to ~10 Hz instead.
    private var lastHostStateWrite: Date = .distantPast

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
            self.publishHostState(phase: .recording, level: level)
        }
        recorder.onReady = { [weak self] in
            guard let self else { return }
            if case .warmingUp = self.status {
                self.status = .recording(level: 0)
            }
            self.publishHostState(phase: .recording, level: 0, force: true)
        }
        recorder.onStartFailed = { [weak self] error in
            guard let self else { return }
            self.status = .error(error.localizedDescription)
            self.tearDownKeyboardHostState()
        }
        pressFeedback.prepare()
        resultFeedback.prepare()
        // Stamp a fresh readiness snapshot on every host launch so
        // the keyboard's "fast / warm-up / download" hint reflects
        // the real disk state immediately, even before any user
        // action.
        publishModelReadiness()

        // Screenshot-capture hook. When the env var or launch arg below
        // is set we synthesise a "mid-recording" state for the App Store
        // shot: faked level, populated transcript, no real mic or model
        // touched. Off in every regular build path — checked via
        // `ProcessInfo` so it costs nothing at runtime unless wired.
        if ProcessInfo.processInfo.environment["DICTATOR_SCREENSHOT_STATE"] == "recording"
            || CommandLine.arguments.contains("-DictatorScreenshotState_recording")
        {
            recordingMode = .dictation
            isModelLoaded = true
            transcript = "Picking up bread, milk, and a couple of those nice apples from the new place on the corner."
            status = .recording(level: 0.55)
        }
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
            recordingMode = .dictation
            // Snapshot the current transcript BEFORE clearing, so the
            // undo button can restore what the user had before they
            // started this dictation cycle.
            previousTranscript = transcript
            transcript = ""
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            recorder.start()
            // Drive the keyboard's "in flight" UI as soon as we
            // start — onLevel/onReady will keep ticking but the
            // initial .warmingUp lands without waiting for the first
            // sample buffer.
            publishHostState(phase: .warmingUp, level: 0, force: true)
            startStopWatcher()
            startHeartbeat()
        default:
            // Already capturing or busy.
            return
        }
    }

    /// Hold-to-talk handler for the purple Assist button — applies a
    /// spoken instruction to the current transcript. No-op if there's
    /// no transcript to operate on (the UI disables the button in that
    /// state, but guarded here too in case of races).
    func startAssistRecording() {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard AppleFoundationAssist.isAvailable else { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = .assist
            // Snapshot the transcript so undo can restore it after
            // the transformation lands. We don't clear here — assist
            // transforms the existing content rather than replacing
            // it wholesale.
            previousTranscript = transcript
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            recorder.start()
            // Mirror the dictation-mode keyboard plumbing: publish a
            // heartbeat + start the stop-request watcher when the
            // assist flow was kicked off from the keyboard. No-ops
            // when there's no keyboard session, so calling
            // unconditionally is cheap.
            publishHostState(phase: .warmingUp, level: 0, force: true)
            startStopWatcher()
            startHeartbeat()
        default:
            return
        }
    }

    /// Counterpart to `startAssistRecording`. Drains the recorder,
    /// transcribes via Parakeet (the spoken INSTRUCTION), then feeds
    /// it together with the existing transcript into Apple Foundation
    /// Models. Result replaces the transcript; the prior version is
    /// saved as the history entry's `raw` so the user can compare /
    /// roll back via the long-press menu.
    func stopAssistRecording() async {
        guard status.isCapturing else { return }
        let samples = recorder.stop()
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        let originalText = transcript
        do {
            let rawInstruction = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            // See `stopRecording` — successful transcribe proves the
            // model loaded, so keep the bridge in sync even when the
            // prewarm path didn't run or raced.
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            // Resolve spoken cues in the instruction itself ("comma",
            // "new paragraph" etc. should map to their glyphs) before
            // handing to the foundation model, but skip the Vocabulary
            // pass — the user's vocab is for their dictation output,
            // not for transformation instructions.
            let instruction = SpokenCues.apply(to: rawInstruction, options: DictatorIOSSettings.cueOptions)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else {
                status = .ready
                recordingMode = .dictation
                return
            }
            let result = try await AppleFoundationAssist.transform(
                text: originalText,
                instruction: instruction
            )
            transcript = result
            DictationHistoryStore.shared.append(result, raw: originalText, mode: .assist)

            // Keyboard-driven assist: write the result back with
            // replacePrecedingCharacters set to the original
            // surrounding text length so the keyboard deletes the
            // old text and inserts the transformed version in
            // place. Skipped when this wasn't a keyboard flow.
            if let session = activeKeyboardSession {
                KeyboardBridge.writeResult(.init(
                    session: session,
                    text: result,
                    replacePrecedingCharacters: originalText.count,
                    createdAt: Date()
                ))
                activeKeyboardSession = nil
            }
            tearDownKeyboardHostState()

            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            // Keep the user's original text on failure — they spoke
            // an instruction expecting a transformation; reverting to
            // raw would lose their intent and confuse the rollback.
            transcript = originalText
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            tearDownKeyboardHostState()
        }
        recordingMode = .dictation
    }

    /// Gated entry point for the first-launch download CTA. Snapshots
    /// the current network path via `NWPathMonitor`; if the device is
    /// on Wi-Fi (the happy path) the download starts immediately, no
    /// extra friction. If the device is on cellular — or we couldn't
    /// determine the link in time — we surface a confirmation alert
    /// via `cellularConfirmationPending` so the view can warn the user
    /// about the ~460 MB hit to their data plan before kicking it off.
    ///
    /// App Review keys on this: a 460 MB silent cellular download is
    /// well over the historic ~200 MB threshold and would get pushed
    /// back at submission.
    func confirmAndDownloadModel() async {
        guard case .notDownloaded = modelDiskStatus else { return }
        if await Self.isOnCellular() {
            cellularConfirmationPending = true
        } else {
            await downloadModel()
        }
    }

    /// Snapshot the current network path's interface and return true
    /// if it's cellular (or we couldn't get a path within the 1 s
    /// budget, in which case the safer choice is to ask the user).
    /// Deliberately one-shot: instantiate, await first update, cancel.
    /// A persistent path monitor would be overkill for a check the
    /// user only cares about at tap-time.
    private static func isOnCellular() async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "dictator.network.snapshot")
        // Wrap the callback-shaped API in a continuation. The path
        // handler can fire more than once on real devices (initial
        // pessimistic snapshot, then the real result a beat later),
        // so guard the resume with a flag and always cancel after
        // the first delivery.
        let onCellular: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let state = MonitorState()
            monitor.pathUpdateHandler = { path in
                guard state.resumeIfPossible() else { return }
                let cellular = path.usesInterfaceType(.cellular)
                monitor.cancel()
                continuation.resume(returning: cellular)
            }
            monitor.start(queue: queue)
            // Safety net: if no callback lands within 1 s (rare but
            // possible on a brand-new launch before the framework
            // has computed a path), assume cellular and let the user
            // make the call. Cheap defensive bound — 1 s is invisible
            // tied to a button tap, and the alternative (silent
            // 460 MB download on cellular) is worse.
            queue.asyncAfter(deadline: .now() + 1.0) {
                guard state.resumeIfPossible() else { return }
                monitor.cancel()
                continuation.resume(returning: true)
            }
        }
        return onCellular
    }

    /// Tiny lock around the path-monitor continuation so the timeout
    /// race and the real callback can't both resume it. Defined as a
    /// nested final class because Swift's continuations are
    /// single-shot — double-resume is a crash, not a warning.
    private final class MonitorState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func resumeIfPossible() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
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
            publishModelReadiness()
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
        publishModelReadiness()
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
        publishModelReadiness()
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
                self.publishModelReadiness()
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
            tearDownKeyboardHostState()
            return
        }

        status = .transcribing
        publishHostState(phase: .transcribing, level: 0, force: true)

        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            // A successful transcribe proves the model is loaded —
            // `transcribe` itself calls `ensureLoaded` and would have
            // thrown if the load failed. The prewarm path also sets
            // this, but if prewarm got skipped or raced weirdly and
            // it was actually `transcribe`'s ensureLoaded that did
            // the load, the flag would otherwise stay false forever
            // and the keyboard chip would never go green.
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
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
            DictationHistoryStore.shared.append(processed, raw: raw, mode: .dictation)

            // If this dictation was triggered from the keyboard
            // extension, hand the result back via the App Group so
            // the keyboard can insert it when the user returns to
            // the original app. Cleared after writing so a manual
            // re-record can't accidentally re-fire the same session.
            if let session = activeKeyboardSession {
                KeyboardBridge.writeResult(.init(
                    session: session,
                    text: processed,
                    replacePrecedingCharacters: 0,
                    createdAt: Date()
                ))
                activeKeyboardSession = nil
            }
            // Clear the in-flight heartbeat + stop watcher whether or
            // not this run was keyboard-driven — cheap no-op for the
            // non-keyboard path.
            tearDownKeyboardHostState()

            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            tearDownKeyboardHostState()
        }
    }

    /// Publish a host-state heartbeat to the App Group container so
    /// the Dictator keyboard can render a recording / transcribing
    /// UI while it's visible. No-op when there's no keyboard session
    /// driving the recording. Level writes are throttled to ~10 Hz;
    /// phase changes always go through immediately so transitions
    /// like .recording -> .transcribing land without lag.
    private func publishHostState(phase: KeyboardBridge.HostState.Phase, level: Float, force: Bool = false) {
        guard let session = activeKeyboardSession else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastHostStateWrite) < 0.1 { return }
        lastHostStateWrite = now
        KeyboardBridge.writeHostState(.init(
            session: session,
            phase: phase,
            level: level,
            updatedAt: now
        ))
    }

    /// Kick off the background poll that watches for a Stop request
    /// from the keyboard during a keyboard-driven recording. Cheap —
    /// just a UserDefaults read every 250 ms. Cancels itself when
    /// `activeKeyboardSession` clears.
    private func startStopWatcher() {
        stopWatcherTask?.cancel()
        guard let session = activeKeyboardSession else { return }
        stopWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard self.activeKeyboardSession == session else { return }
                if KeyboardBridge.consumeStopRequest(matching: session) {
                    // Dispatch to the correct stop method based on
                    // the current recording mode — assist needs to
                    // run the transform, dictation just transcribes.
                    if self.recordingMode == .assist {
                        await self.stopAssistRecording()
                    } else {
                        await self.stopRecording()
                    }
                    return
                }
            }
        }
    }

    /// Liveness heartbeat — re-stamps the host-state entry every 3s
    /// so the keyboard's "is this still alive?" check sees a fresh
    /// timestamp during long transcriptions. Without this the
    /// keyboard would falsely treat any transcription past its
    /// staleness threshold as a dead host. Lightweight — one
    /// UserDefaults read + one write per tick.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let session = activeKeyboardSession else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard self.activeKeyboardSession == session else { return }
                // Just bump updatedAt. Phase + level stay as last
                // written — onLevel re-writes those during recording.
                if let current = KeyboardBridge.readHostState(), current.session == session {
                    var fresh = current
                    fresh.updatedAt = Date()
                    KeyboardBridge.writeHostState(fresh)
                }
            }
        }
    }

    /// Cancel the poll + heartbeat tasks and clear the state
    /// heartbeat the keyboard might be reading.
    private func tearDownKeyboardHostState() {
        stopWatcherTask?.cancel()
        stopWatcherTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        KeyboardBridge.clearHostState()
    }

    /// Abort a recording mid-flight without transcribing or sending
    /// anything back. Used by the keyboard-mode banner's X button —
    /// the user wants out, not a stale transcript landing later.
    /// Safe to call when nothing's recording (no-op).
    func cancelRecording() {
        if status.isCapturing {
            _ = recorder.stop()
            status = .idle
            recordingMode = .dictation
            resultFeedback.notificationOccurred(.warning)
        }
        activeKeyboardSession = nil
        tearDownKeyboardHostState()
    }

    /// Drive the bridge's foreground tracking from a scenePhase
    /// callback. Writes the host-active flag so the keyboard can
    /// auto-dismiss inside the host's own app, and re-publishes the
    /// readiness snapshot on a transition to active so the keyboard's
    /// chip reflects the latest in-process state (which the keyboard
    /// reads on appear). No timer — the bridge is updated at the
    /// natural lifecycle points where the readiness can have changed.
    func applyForegroundState(_ active: Bool) {
        KeyboardBridge.writeHostActive(active)
        if active {
            publishModelReadiness()
        }
    }

    /// Publish the model's disk + memory status to the App Group so
    /// the Dictator keyboard can render a "fast / slow / not yet
    /// downloaded" hint. Called at every lifecycle transition that
    /// touches model state. Cheap — single JSON encode + UserDefaults
    /// write, fires only on transitions, not in any hot path.
    private func publishModelReadiness() {
        let disk: KeyboardBridge.ModelReadiness.DiskStatus
        switch modelDiskStatus {
        case .downloaded: disk = .downloaded
        default:          disk = .notDownloaded
        }
        KeyboardBridge.writeModelReadiness(.init(
            diskStatus: disk,
            modelID: selectedModelID,
            loaded: isModelLoaded,
            updatedAt: Date()
        ))
    }

    /// True when there's a meaningful snapshot to swap to. Used by
    /// the UI to show / hide the floating undo button on the
    /// transcript card.
    var canUndo: Bool {
        guard let prev = previousTranscript else { return false }
        return prev != transcript
    }

    /// Toggle current ↔ previous transcript. First tap behaves as
    /// undo (restore the snapshot taken at the start of the last
    /// recording); a second tap returns the post-recording text,
    /// effectively acting as redo. Light haptic so the user knows
    /// something happened — the visual change is the only other cue.
    func undo() {
        guard let prev = previousTranscript, prev != transcript else { return }
        let current = transcript
        transcript = prev
        previousTranscript = current
        pressFeedback.impactOccurred()
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
