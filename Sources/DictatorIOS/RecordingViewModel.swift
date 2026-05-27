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
    ///
    /// The `.downloading` case carries a full progress snapshot so the
    /// UI can render bytes / total / rate without having to reach into
    /// the downloader directly. The legacy `progress: Double` field is
    /// preserved for any consumer that just wants a fractional value.
    enum ModelDiskStatus: Equatable {
        case checking
        case notDownloaded
        case downloading(progress: Double, snapshot: BackgroundModelDownloader.Progress)
        case paused(snapshot: BackgroundModelDownloader.Progress, reason: String?)
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

    /// Set when the host has been launched by the keyboard extension.
    /// True only while a recording that we started *for* the user
    /// (not from a button press) is in flight. Currently set when
    /// arriving via the keyboard URL launch — the user already
    /// pressed in the keyboard, so a hold-to-talk affordance on
    /// arrival would be wrong; tap-to-stop fits. Cleared as soon as
    /// that recording ends; any subsequent presses inside the app
    /// use the regular hold gesture.
    private(set) var autoStartedRecordingActive: Bool = false

    /// Wall-clock seconds between `.transcribing` and `.ready` for the
    /// most recent successful run. Surfaced in the status pill's idle
    /// state ("Idle · 1.2s") so the user can see how fast the round-
    /// trip was. Cleared on `clear()` and on the start of a fresh
    /// recording so a stale duration doesn't linger past relevance;
    /// also cleared on a failed run (no successful transcription, no
    /// duration to advertise).
    private(set) var lastTranscriptionDuration: TimeInterval?

    /// Monotonic counter incremented on each press. The UI uses it as
    /// an `.id(...)` value on the waveform view so a new recording
    /// gets a fresh component instance — without this the waveform's
    /// internal `bars` @State would carry over from the previous
    /// recording, and the leftover bars would flash visible the
    /// instant the new recording started.
    private(set) var recordingStartCount: Int = 0

    /// Timestamp captured at `.transcribing` entry — paired with the
    /// `.ready` transition to compute `lastTranscriptionDuration`.
    private var transcribingStartedAt: Date?

    /// User-editable. Bound from `TextEditor` so the user can tweak the
    /// transcribed result before copying. The view model writes it on
    /// transcribe-complete (cursor-aware merge — see `mergeTranscribed`)
    /// and on `clear()`; everything else is the user typing.
    var transcript: String = ""
    /// Live caret / selection in the transcript editor. Bound back
    /// from the UIKit-backed `EditableTranscript` view so a transcribed
    /// chunk can land at the user's cursor (or replace their
    /// highlighted range) rather than always appending at the end.
    /// `nil` while the field has never been focused; the merge helper
    /// falls back to append.
    ///
    /// `NSRange` (not `Range<String.Index>`) because UITextView speaks
    /// UTF-16 offsets natively — round-tripping through String.Index on
    /// every selection change would be both slower and more bug-prone
    /// at grapheme boundaries.
    var transcriptSelection: NSRange?
    /// One-step undo target. Snapshotted at the start of each
    /// dictation / assist press AND on `clear()` — i.e. just before any
    /// programmatic mutation of `transcript`. The undo button toggles
    /// current / previous, so a second tap acts as redo.
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

    /// Periodic re-write of the host-active flag in `KeyboardBridge`
    /// while the app is foregrounded. The keyboard extension's
    /// "don't render inside Dictator" check looks at the flag's
    /// freshness (60s window), so without this heartbeat the flag
    /// would age out for a user sitting in Dictator without
    /// backgrounding — and Dictator's keyboard would start showing
    /// up inside Dictator again. 30s interval keeps it well within
    /// the freshness budget. Cancelled when the app backgrounds.
    private var hostActiveHeartbeatTask: Task<Void, Never>?

    /// Throttled timestamp of the last host-state write — keeps the
    /// `onLevel` callback from hammering UserDefaults at the audio
    /// buffer rate (~20 Hz). Caps writes to ~10 Hz instead.
    private var lastHostStateWrite: Date = .distantPast

    /// Lightweight tactile feedback on press/release/result. Generators
    /// are held strongly so they're warm when the user taps — first-use
    /// initialisation otherwise produces a noticeable lag on the haptic.
    private let pressFeedback = UIImpactFeedbackGenerator(style: .light)
    private let resultFeedback = UINotificationFeedbackGenerator()

    /// Long-lived observer that mirrors `BackgroundModelDownloader.shared`
    /// state into our `modelDiskStatus` so the existing UI bindings
    /// don't need to know about the downloader directly. Started the
    /// first time we kick off a download (lazy — first launches without
    /// a model don't pay for it) and stays alive for the rest of the
    /// process lifetime; the downloader is a singleton, so observing it
    /// continuously is cheap.
    private var downloaderObserverTask: Task<Void, Never>?

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

        // Reflect the background downloader's state into ours from
        // launch. The AppDelegate also calls `bootstrapOnLaunch`, which
        // resurrects any in-flight session and replays delegate events;
        // observing here means the UI shows a resumed-mid-flight bar
        // immediately on cold launch if the previous session was
        // interrupted.
        startDownloaderObserverIfNeeded()
        if case .notDownloaded = modelDiskStatus {
            // applyDownloaderState seeds from current state on first
            // tick, so this just forces an immediate read.
            applyDownloaderState(BackgroundModelDownloader.shared.state)
        }

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
    func startRecording(snapshotForUndo: Bool = true) {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = .dictation
            // Fresh waveform on every press; bump the counter the UI
            // keys its `.id(...)` off so SwiftUI rebuilds a clean
            // component instead of carrying the previous run's bars.
            recordingStartCount &+= 1
            // Clear the prior duration so the pill goes from
            // "Idle · 1.2s" to plain "Idle" (then bars) as soon as
            // the new run begins.
            lastTranscriptionDuration = nil
            // Snapshot the current transcript BEFORE the merge so undo
            // can restore what the user had before they started this
            // dictation cycle. We *don't* clear — multi-shot dictation
            // appends (or replaces a selection) via `mergeTranscribed`.
            // Callers that have already staged a snapshot themselves
            // (e.g. the keyboard-record arrival path, which pre-clears
            // the transcript and wants undo to recover the pre-clear
            // text) pass `snapshotForUndo: false` so we don't clobber
            // their setup.
            if snapshotForUndo {
                previousTranscript = transcript
            }
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
            recordingStartCount &+= 1
            lastTranscriptionDuration = nil
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
            // Empty-samples early-return used to skip the keyboard
            // teardown, which left the keyboard side stuck on its
            // "recording" UI until the 30s freshness window expired.
            // Always clean up the host-state heartbeat and auto-record
            // flag on the way out.
            status = .idle
            recordingMode = .dictation
            autoStartedRecordingActive = false
            tearDownKeyboardHostState()
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
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
                // Same teardown as the success path — the host wrote
                // "transcribing" to the bridge above, the keyboard
                // needs to see that we're no longer in flight.
                transcribingStartedAt = nil
                status = .ready
                recordingMode = .dictation
                autoStartedRecordingActive = false
                tearDownKeyboardHostState()
                return
            }
            let result = try await AppleFoundationAssist.transform(
                text: originalText,
                instruction: instruction
            )
            transcript = result
            // Invalidate the stale TextSelection — its indices were
            // sampled against `originalText`, and the wholesale swap
            // makes them meaningless.
            transcriptSelection = nil
            // See stopRecording — auto-copy keeps the keyboard's
            // Paste pill primed without needing an explicit Send.
            publishTranscriptToClipboard()
            DictationHistoryStore.shared.append(result, raw: originalText, mode: .assist)
            UsageStatsStore.shared.record(
                mode: .assistant,
                wordsIn: UsageStatsStore.wordCount(instruction),
                wordsOut: UsageStatsStore.wordCount(result)
            )

            // Per-recording teardown only — the keyboard session
            // stays alive across multi-shot edits until the user
            // explicitly hits Send.
            autoStartedRecordingActive = false
            tearDownKeyboardHostState()

            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            // Keep the user's original text on failure — they spoke
            // an instruction expecting a transformation; reverting to
            // raw would lose their intent and confuse the rollback.
            transcript = originalText
            transcriptSelection = nil
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            autoStartedRecordingActive = false
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
        // Accept `.notDownloaded`, `.failed`, or `.checking` as valid
        // "try downloading" entry points. The pre-existing guard only
        // accepted `.notDownloaded`, which silently no-op'd taps from
        // the onboarding sheet when the view model hadn't yet finished
        // its disk probe (`.checking`) OR when a previous attempt had
        // failed (`.failed`) — looking exactly like "the button does
        // nothing" from the user's side. Reset failed state so the
        // downstream guard doesn't reject the retry.
        switch modelDiskStatus {
        case .downloaded, .downloading, .paused:
            NSLog("[Dictator iOS] confirmAndDownloadModel: ignoring tap — already in \(modelDiskStatus)")
            return
        case .failed:
            modelDiskStatus = .notDownloaded
        case .notDownloaded, .checking:
            break
        }
        let onCellular = await Self.isOnCellular()
        NSLog("[Dictator iOS] confirmAndDownloadModel: cellular=\(onCellular)")
        if onCellular {
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
    /// Triggered by the first-launch CTA.
    ///
    /// Routes through `BackgroundModelDownloader` rather than calling
    /// FluidAudio's foreground downloader directly. The background path
    /// survives app suspension (lock screen, app switch) and persists
    /// per-file resume data so a flaky connection — or a relaunch —
    /// picks up where it left off instead of starting the whole 460 MB
    /// over. Once the downloader reports completion the on-disk layout
    /// matches what FluidAudio's loader expects, so the model loads
    /// lazily on the first recording press without a second network
    /// round trip.
    func downloadModel() async {
        switch modelDiskStatus {
        case .downloaded:
            NSLog("[Dictator iOS] downloadModel: already downloaded, no-op")
            return
        default: break
        }
        NSLog("[Dictator iOS] downloadModel: starting BackgroundModelDownloader for \(selectedModelID)")
        startDownloaderObserverIfNeeded()
        await BackgroundModelDownloader.shared.startDownload(modelID: selectedModelID)
    }

    /// Pause the active download. Resume data is persisted so a
    /// subsequent `downloadModel()` continues mid-file rather than
    /// restarting whichever chunk was in flight.
    func pauseDownload() async {
        await BackgroundModelDownloader.shared.pause()
    }

    /// Drop the in-flight download entirely. Clears the manifest and
    /// any persisted resume data. The next download starts from
    /// scratch.
    func cancelDownload() async {
        await BackgroundModelDownloader.shared.cancel()
    }

    /// Idempotent: start an observation loop over the downloader's
    /// `state` property and mirror it into `modelDiskStatus`. Uses
    /// `withObservationTracking` in a loop so SwiftUI-style observation
    /// surfaces the changes without us reaching for any KVO / Combine
    /// machinery. The loop exits naturally when the task is cancelled.
    private func startDownloaderObserverIfNeeded() {
        guard downloaderObserverTask == nil else { return }
        downloaderObserverTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // withObservationTracking only fires once — re-arm by
                // looping. Using a continuation here lets us wait on the
                // next change without busy-spinning.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        self.applyDownloaderState(BackgroundModelDownloader.shared.state)
                    } onChange: {
                        // onChange fires off the observation queue; hop
                        // back to main for the next iteration's
                        // applyDownloaderState read.
                        Task { @MainActor in continuation.resume() }
                    }
                }
            }
        }
    }

    /// Translate the downloader's state into our `ModelDiskStatus`
    /// shape. `.completed` triggers a one-time bridge re-publish so the
    /// keyboard's readiness chip updates immediately.
    private func applyDownloaderState(_ state: BackgroundModelDownloader.State) {
        switch state {
        case .idle:
            // Re-check disk status — the downloader may have been
            // cancelled and the manifest cleared.
            if ParakeetService.modelsExist(id: selectedModelID) {
                modelDiskStatus = .downloaded
            } else if case .downloaded = modelDiskStatus {
                modelDiskStatus = .notDownloaded
            } else if case .failed = modelDiskStatus {
                // Keep failure visible until the user explicitly retries.
            } else {
                modelDiskStatus = .notDownloaded
            }
        case .listing:
            // Show a 0% bar with placeholder counts so the UI moves the
            // moment the user taps Download. The first real
            // `didWriteData` will overwrite this.
            modelDiskStatus = .downloading(
                progress: 0,
                snapshot: .zero
            )
        case .downloading(let snapshot):
            modelDiskStatus = .downloading(progress: snapshot.fraction, snapshot: snapshot)
        case .paused(let snapshot, let reason):
            modelDiskStatus = .paused(snapshot: snapshot, reason: reason)
        case .completed:
            modelDiskStatus = .downloaded
            publishModelReadiness()
        case .failed(let message):
            modelDiskStatus = .failed(message)
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
        // If a download for the previous variant was in flight (or
        // paused / failed), drop it. The observer would otherwise
        // overwrite our `.notDownloaded` with the previous model's
        // download state on its next tick — and the manifest on disk
        // is for the old model, so resuming a v3 download under a v2
        // selection would land bytes in the wrong place.
        Task { await BackgroundModelDownloader.shared.cancel() }
        // Re-evaluate disk presence for the newly-selected variant so
        // the UI transitions to the download CTA when needed (and out
        // of it when the user picks a variant they already have).
        modelDiskStatus = ParakeetService.modelsExist(id: id) ? .downloaded : .notDownloaded
        publishModelReadiness()
    }

    /// Exit path from the failed-download screen. Clears the
    /// downloader's failure state AND any persisted manifest / resume
    /// data so the user can choose to come back later without the
    /// observer immediately overwriting the local "notDownloaded" back
    /// to "failed". Used by the "Come back later" button on the
    /// failure UI; the "Try again" button calls `downloadModel()`
    /// directly which preserves resume data.
    func resetDownload() {
        Task { await BackgroundModelDownloader.shared.cancel() }
        modelDiskStatus = .notDownloaded
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
            autoStartedRecordingActive = false
            tearDownKeyboardHostState()
            return
        }

        status = .transcribing
        transcribingStartedAt = Date()
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

            mergeTranscribed(processed)
            // Auto-copy the (possibly-built-up) transcript and stash
            // a preview snapshot so the keyboard's Paste pill is
            // primed without needing an explicit Send. See
            // `publishTranscriptToClipboard`.
            publishTranscriptToClipboard()
            // Keep the raw Parakeet text alongside the polished delivery
            // so the history detail can show "what I actually heard"
            // when the user wants to recover something the cleanup
            // pass smoothed over. History records the chunk itself —
            // not the full transcript — so each dictation press lands
            // as its own entry even when the transcript field is
            // building up across multiple presses.
            DictationHistoryStore.shared.append(processed, raw: raw, mode: .dictation)
            UsageStatsStore.shared.record(
                mode: .dictation,
                wordsIn: UsageStatsStore.wordCount(raw),
                wordsOut: UsageStatsStore.wordCount(processed)
            )

            // Tear down per-recording heartbeat / stop-watcher. The
            // keyboard session itself stays alive so the user can
            // append more dictations or edit before hitting Send.
            // Cheap no-op for the non-keyboard path.
            autoStartedRecordingActive = false
            tearDownKeyboardHostState()

            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            autoStartedRecordingActive = false
            tearDownKeyboardHostState()
        }
    }

    /// Publish a host-state heartbeat to the App Group container so
    /// the Dictator keyboard can render a recording / transcribing
    /// UI while it's visible. Fires for any recording (not just
    /// keyboard-initiated ones) — in-app dictations also publish, but
    /// the keyboard auto-dismisses inside Dictator so no one's
    /// watching. Level writes are throttled to ~10 Hz; phase changes
    /// always go through immediately so transitions like
    /// .recording -> .transcribing land without lag.
    private func publishHostState(phase: KeyboardBridge.HostState.Phase, level: Float, force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastHostStateWrite) < 0.1 { return }
        lastHostStateWrite = now
        KeyboardBridge.writeHostState(.init(
            session: UUID(),
            phase: phase,
            level: level,
            updatedAt: now
        ))
    }

    /// Kick off the background poll that watches for a Stop request
    /// from the keyboard. Cheap — a UserDefaults read every 250 ms.
    /// Runs for the duration of any recording; the keyboard only
    /// sends stop requests when its in-flight UI is visible, so the
    /// poll is a no-op for in-app recordings.
    private func startStopWatcher() {
        stopWatcherTask?.cancel()
        stopWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard self.status.isCapturing else { return }
                if KeyboardBridge.consumeAnyStopRequest() {
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
    /// staleness threshold as a dead host.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                guard self.status.isCapturing || {
                    if case .transcribing = self.status { return true } else { return false }
                }() else { return }
                if let current = KeyboardBridge.readHostState() {
                    var fresh = current
                    fresh.updatedAt = Date()
                    KeyboardBridge.writeHostState(fresh)
                }
            }
        }
    }

    /// Cancel the poll + heartbeat tasks and clear the state slot
    /// the keyboard reads. Called from recording-end paths so the
    /// keyboard's in-flight UI retracts promptly.
    private func tearDownKeyboardHostState() {
        stopWatcherTask?.cancel()
        stopWatcherTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        KeyboardBridge.clearHostState()
    }

    /// Abort a recording mid-flight without transcribing. Safe to
    /// call when nothing's recording (no-op on status).
    func cancelRecording() {
        if status.isCapturing {
            _ = recorder.stop()
            status = .idle
            recordingMode = .dictation
            resultFeedback.notificationOccurred(.warning)
        }
        autoStartedRecordingActive = false
        tearDownKeyboardHostState()
    }

    /// Entry point called when the host is launched by the keyboard
    /// extension URL handler. Pre-populates the transcript (clears it
    /// for `.record`, takes the captured surrounding text for
    /// `.assist`) and auto-starts the recording — the user already
    /// pressed in the keyboard, so making them tap again here would
    /// feel broken. `autoStartedRecordingActive` is set so the UI
    /// picks the tap-to-stop button instead of hold-to-talk; cleared
    /// at the end of this recording, so any subsequent presses use
    /// the regular hold gesture.
    func beginKeyboardRecording(mode: KeyboardBridge.Mode, surroundingText: String?) {
        autoStartedRecordingActive = true
        switch mode {
        case .record:
            // Arriving from the keyboard's Dictate tile means a
            // fresh thought to insert in another app — the user
            // wouldn't expect their last in-app transcript to still
            // be sitting there to append to. Snapshot first so undo
            // recovers the pre-clear text, then pass
            // `snapshotForUndo: false` so startRecording doesn't
            // replace the snapshot with the now-empty value.
            if !transcript.isEmpty {
                previousTranscript = transcript
                transcript = ""
                transcriptSelection = nil
            }
            startRecording(snapshotForUndo: false)
        case .assist:
            // The keyboard's `textDocumentProxy.selectedText` is
            // unreliable across iOS apps (Radar FB7789012 — silently
            // truncates the selection to first+last sentence in
            // WebView-backed fields), so the keyboard now hands us
            // nothing and we source the text from the system
            // clipboard instead. The user copies their target text
            // before tapping Assist on the keyboard; we read it
            // here. iOS will fire the "Pasted from X" toast on the
            // read, which is the expected price of any
            // pasteboard-string access since iOS 16.
            transcript = UIPasteboard.general.string ?? ""
            // Pre-select the captured text so the user can
            // immediately re-dictate to replace it (the cursor-aware
            // merge picks the selection up as "replace this range").
            // Assist always transforms the full transcript regardless
            // of selection, so this is purely a UX cue — the mic
            // flips to its replace-mode icon, priming the
            // "actually, scrap this, dictate fresh" path.
            let length = (transcript as NSString).length
            transcriptSelection = length > 0
                ? NSRange(location: 0, length: length)
                : nil
            // If the clipboard was empty we have nothing to assist
            // on — skip the auto-start (startAssistRecording would
            // also no-op on empty transcript, but bailing here keeps
            // the autoStartedRecordingActive flag from latching).
            if transcript.isEmpty {
                autoStartedRecordingActive = false
            } else {
                startAssistRecording()
            }
        }
    }

    /// Drive the bridge's foreground tracking from a scenePhase
    /// callback. Writes the host-active flag so the keyboard can
    /// auto-dismiss inside the host's own app, and re-publishes the
    /// readiness snapshot on a transition to active so the keyboard's
    /// chip reflects the latest in-process state (which the keyboard
    /// reads on appear).
    func applyForegroundState(_ active: Bool) {
        KeyboardBridge.writeHostActive(active)
        if active {
            // Keep the host-active flag fresh while the user is
            // sitting in Dictator — without the heartbeat the flag's
            // 60s freshness window expires and our keyboard starts
            // popping up over Dictator's own UI again.
            startHostActiveHeartbeat()
            publishModelReadiness()
        } else {
            stopHostActiveHeartbeat()
        }
    }

    private func startHostActiveHeartbeat() {
        hostActiveHeartbeatTask?.cancel()
        hostActiveHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                guard self != nil else { return }
                KeyboardBridge.writeHostActive(true)
            }
        }
    }

    private func stopHostActiveHeartbeat() {
        hostActiveHeartbeatTask?.cancel()
        hostActiveHeartbeatTask = nil
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

    /// True when there's text to wipe. Drives the floating clear
    /// button's visibility on the transcript card.
    var canClear: Bool { !transcript.isEmpty }

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
        // Selection indices from the prior string are invalid against
        // the swapped-in text; let TextEditor settle to a fresh caret
        // at the end rather than carry a stale range that could trap.
        transcriptSelection = nil
        pressFeedback.impactOccurred()
    }

    /// Wipe the transcript. Snapshots the current text into
    /// `previousTranscript` first so a misfired clear is one tap of
    /// undo away from recovery. Selection is invalidated. No-op when
    /// already empty.
    func clear() {
        guard !transcript.isEmpty else { return }
        previousTranscript = transcript
        transcript = ""
        transcriptSelection = nil
        // The duration is a stat about the now-wiped transcript;
        // hanging onto it would mean "Idle · 1.2s" reading as if there
        // was still something to show for it.
        lastTranscriptionDuration = nil
        pressFeedback.impactOccurred()
    }

    /// Merge a freshly transcribed chunk into the transcript using the
    /// current selection as the insertion site:
    ///   - Non-empty selection → replace the selected range
    ///   - Empty selection (caret) → insert at the caret with smart
    ///     space padding (skipped when the neighbouring char is
    ///     already whitespace / a closing punctuation mark)
    ///   - No selection at all (field never focused) → append at the
    ///     end, with a single-space separator (or newline after a
    ///     sentence terminator)
    /// Empty / whitespace-only chunks are dropped — there's nothing
    /// meaningful to add and we don't want a stray space appearing.
    private func mergeTranscribed(_ chunk: String) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ns = transcript as NSString
        let total = ns.length

        // Empty transcript → take the chunk verbatim, place the caret
        // at the end so a subsequent edit lands naturally.
        guard total > 0 else {
            transcript = trimmed
            transcriptSelection = NSRange(location: (trimmed as NSString).length, length: 0)
            return
        }

        // Cursor / selection path — guard against a stale range that
        // doesn't fit the current text (e.g. after a manual edit the
        // view model didn't observe yet).
        if let sel = transcriptSelection,
           sel.location >= 0,
           sel.location + sel.length <= total {
            let lead: String
            let trail: String
            if sel.length == 0 {
                // Inserting at a caret — pad to avoid concatenation
                // when the neighbouring character isn't already a
                // space or a closing punctuation glyph.
                lead = needsLeadingSpace(in: ns, before: sel.location) ? " " : ""
                trail = needsTrailingSpace(in: ns, after: sel.location + sel.length) ? " " : ""
            } else {
                // Replacing the user's explicit selection — their
                // boundaries are intentional, padding would corrupt
                // them. "Helloworld" with "world" selected and
                // dictation "people" should yield "Hellopeople", not
                // "Hello people".
                lead = ""
                trail = ""
            }
            let insertion = lead + trimmed + trail
            transcript = ns.replacingCharacters(in: sel, with: insertion)
            let leadLength = (lead as NSString).length
            let trimmedLength = (trimmed as NSString).length
            let insertedLength = (insertion as NSString).length

            if sel.length > 0 {
                // Replaced a selection — keep the new content
                // selected (sans any padding, which is empty in this
                // branch) so the user can immediately re-dictate to
                // try a different replacement.
                transcriptSelection = NSRange(
                    location: sel.location + leadLength,
                    length: trimmedLength
                )
            } else {
                // Pure caret insertion — drop the caret at the end
                // of the inserted text so the user can continue
                // dictating to extend it.
                transcriptSelection = NSRange(
                    location: sel.location + insertedLength,
                    length: 0
                )
            }
            return
        }

        // Fallback: append at end with a sentence-aware separator.
        let separator = endOfTranscriptSeparator()
        transcript += separator + trimmed
        let newLength = (transcript as NSString).length
        transcriptSelection = NSRange(location: newLength, length: 0)
    }

    /// True when inserting before `loc` would butt up against a
    /// non-space character. The closing-punctuation set is *not*
    /// included here — they live on the trailing side.
    private func needsLeadingSpace(in ns: NSString, before loc: Int) -> Bool {
        guard loc > 0, loc <= ns.length else { return false }
        let ch = ns.substring(with: NSRange(location: loc - 1, length: 1))
        guard let c = ch.first else { return false }
        return !c.isWhitespace && !c.isNewline
    }

    /// True when inserting after `loc` would butt up against a
    /// non-space character and that character isn't a closing
    /// punctuation glyph (we don't want " ." or " ,").
    private func needsTrailingSpace(in ns: NSString, after loc: Int) -> Bool {
        guard loc >= 0, loc < ns.length else { return false }
        let ch = ns.substring(with: NSRange(location: loc, length: 1))
        guard let c = ch.first else { return false }
        if c.isWhitespace || c.isNewline { return false }
        return !".,!?;:)]}".contains(c)
    }

    /// Separator used between the existing transcript and the new
    /// chunk when no selection / caret is present. Sentence terminators
    /// get a newline (treating each end-of-sentence dictation as a
    /// fresh thought worth visually separating); everything else gets
    /// a plain space.
    private func endOfTranscriptSeparator() -> String {
        guard let last = transcript.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        if ".!?".contains(last) { return "\n" }
        return " "
    }

    /// User-tapped Copy. Pushes the current transcript through the
    /// same clipboard + bridge-snapshot pipeline auto-copy uses, so
    /// the Dictator keyboard's preview pill stays in sync with what
    /// will actually paste (a manual Copy after editing has to bump
    /// the snapshot's `changeCount` too, otherwise the keyboard
    /// would hide its preview because the stored count no longer
    /// matches the pasteboard's).
    func copyTranscriptToClipboard() {
        guard !transcript.isEmpty else { return }
        publishTranscriptToClipboard()
        resultFeedback.notificationOccurred(.success)
    }

    /// Single source of truth for "put the current transcript on the
    /// system clipboard and tell the keyboard about it". Called from
    /// the success paths of stopRecording / stopAssistRecording as
    /// well as the manual Copy button — keeps the auto and manual
    /// paths from drifting out of sync.
    private func publishTranscriptToClipboard() {
        UIPasteboard.general.string = transcript
        KeyboardBridge.writeLastDictation(.init(
            text: transcript,
            pasteboardChangeCount: UIPasteboard.general.changeCount,
            writtenAt: Date()
        ))
    }
}
