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
        /// Capturing. Deliberately carries no level: `status` should change
        /// only when the phase does, because every view that reads it
        /// re-renders when it changes. The level is `levelMeter`'s.
        case recording
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
        /// The Scratchpad tab's mic — output is merged into the synced
        /// `ScratchpadModel.shared` note (cursor/selection-aware) instead of
        /// the transcript editor.
        case scratchpad
        /// The Scratchpad tab's assist button — a spoken instruction
        /// transforms the selected note text (or the whole note when nothing
        /// is selected).
        case scratchpadAssist
        /// Started from the keyboard (or the Live Activity) while Dictator
        /// is in the background holding a warm mic. The result goes back
        /// to the keyboard to insert, and onto the clipboard — never into
        /// the transcript editor, which the user can't see.
        case keyboard
        /// As `.keyboard`, but the speech is an instruction applied to
        /// `keyboardSourceText`.
        case keyboardAssist
        /// The Journal tab's mic — appended to today's journal file.
        case journal
        /// The mic inside the journal's entry editor — the words go back to
        /// the editor at its cursor, not to a file.
        case entry
        /// The editor's Reword button: the speech is an instruction applied
        /// to the editor's selection, or its whole text.
        case entryAssist
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

    private(set) var status: Status = .idle {
        didSet {
            syncBackgroundSession()
            if !status.isCapturing, levelMeter.level != 0 { levelMeter.level = 0 }
        }
    }
    /// The live mic level, apart from `status` so a level update only
    /// redraws the meters that read it.
    let levelMeter = LevelMeter()
    /// True between `recorder.stop()` and its samples being ready, so a
    /// second stop (a tap landing as a hold ends) can't race the first.
    @ObservationIgnored private var isDrainingCapture = false
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
    /// The keyboard opened the app to start this recording and is waiting
    /// for its result. iOS gives no way to send the user back to the app
    /// they came from, so the UI points them at the status bar's ◀ link.
    var isKeyboardHandoff: Bool {
        autoStartedRecordingActive && servingID != nil && status.isCapturing
    }

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
    /// Live Activity, keyboard heartbeat and warm-mic lifetime.
    private let session = BackgroundSession()
    /// The keyboard command or URL-launch session the current capture is
    /// for. Its result is written back to the keyboard to insert.
    private var servingID: UUID?
    /// `.keyboardAssist` only: the text the keyboard handed over to transform.
    private var keyboardSourceText: String?
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

    /// Periodic re-write of the host-active flag in `KeyboardBridge`
    /// while the app is foregrounded. The keyboard extension's
    /// "don't render inside Dictator" check looks at the flag's
    /// freshness (60s window), so without this heartbeat the flag
    /// would age out for a user sitting in Dictator without
    /// backgrounding — and Dictator's keyboard would start showing
    /// up inside Dictator again. 30s interval keeps it well within
    /// the freshness budget. Cancelled when the app backgrounds.
    private var hostActiveHeartbeatTask: Task<Void, Never>?

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
            ?? DictatorIOSSettings.recommendedModelID()
        selectedModelID = storedID
        // Cheap synchronous filesystem check — no network, no model
        // touched. Drives the first-launch UI: if the model isn't on
        // disk we show a download prompt instead of the recording UI.
        modelDiskStatus = ParakeetService.modelsExist(id: storedID) ? .downloaded : .notDownloaded
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.session.updateLevel(level)
            if case .warmingUp = self.status {
                self.status = .recording
            }
            if case .recording = self.status {
                self.levelMeter.level = level
            }
        }
        recorder.onReady = { [weak self] in
            guard let self else { return }
            if case .warmingUp = self.status {
                self.status = .recording
            }
        }
        recorder.onStartFailed = { [weak self] error in
            guard let self else { return }
            self.deliverKeyboardResult(text: nil, error: "Couldn't start the microphone. Open Dictator and try again.")
            self.status = .error(error.localizedDescription)
        }
        recorder.onInterrupted = { [weak self] in
            self?.handleRecorderInterrupted()
        }
        session.onExpire = { [weak self] in
            self?.endBackgroundSession()
        }
        // Keyboard taps reach a backgrounded host as Darwin notifications.
        KeyboardBridge.observeDarwin(KeyboardBridge.commandNotification) { [weak self] in
            self?.handleKeyboardCommand()
        }
        NotificationCenter.default.addObserver(
            forName: .dictationActivityCommand, object: nil, queue: .main
        ) { [weak self] note in
            let command = (note.object as? String).flatMap(DictationActivityCommand.init(rawValue:))
            MainActor.assumeIsolated { self?.handleActivityCommand(command) }
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
        // is set we synthesise a resting post-dictation state for the App
        // Store shot: model loaded, a populated transcript, and a `.ready`
        // (at-rest) status so the mic shows its resting icon rather than
        // the active listening ring — the shot reads as "here's your
        // result, ready to copy" instead of mid-recording. No real mic or
        // model is touched. Off in every regular build path — checked via
        // `ProcessInfo` so it costs nothing at runtime unless wired.
        if ProcessInfo.processInfo.environment["DICTATOR_SCREENSHOT_STATE"] == "recording"
            || CommandLine.arguments.contains("-DictatorScreenshotState_recording")
        {
            recordingMode = .dictation
            isModelLoaded = true
            transcript = "Picking up bread, milk, and a couple of those nice apples from the new place on the corner."
            status = .ready
        }

        #if DEBUG
        applyMorphPreviewIfRequested()
        #endif
    }

    #if DEBUG
    /// Set by `-DictatorMorphPreview <state>`; keeps the downloader from
    /// replacing the faked model state.
    private var isMorphPreview = false

    /// `-DictatorMorphPreview empty|text|recording|assist|working` (launch
    /// arguments land in UserDefaults) fakes a recording state so the morph
    /// button can be seen in a simulator with no model installed. No mic or
    /// model is touched. With `-DictatorInitialTab scratchpad` or `journal`
    /// the recording belongs to that tab instead of Dictate.
    private func applyMorphPreviewIfRequested() {
        guard let state = UserDefaults.standard.string(forKey: "DictatorMorphPreview") else { return }
        isMorphPreview = true
        permission = .granted
        modelDiskStatus = .downloaded
        isModelLoaded = true
        let sample = "Can we move Thursday's review to Friday morning? I'd like one more day with the new builds before we show anyone."
        transcript = state == "empty" ? "" : sample
        let tab = UserDefaults.standard.string(forKey: "DictatorInitialTab")
        let speak: RecordingMode = switch tab {
        case "scratchpad": .scratchpad
        case "journal": .journal
        default: .dictation
        }
        let assist: RecordingMode = tab == "scratchpad" ? .scratchpadAssist : .assist
        switch state {
        case "recording":
            recordingMode = speak
            status = .recording
            levelMeter.level = 0.55
        case "assist":
            recordingMode = assist
            status = .recording
            levelMeter.level = 0.55
        case "working":
            recordingMode = speak
            status = .transcribing
        default:
            status = .idle
        }
    }
    #endif

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
            beginCapture()
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
            beginCapture()
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
        await runProcessing { await self.stopAssistRecordingWork() }
    }

    private func stopAssistRecordingWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            deliverKeyboardResult(text: nil, error: nil)
            status = .idle
            recordingMode = .dictation
            autoStartedRecordingActive = false
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        let originalText = transcript
        do {
            let rawInstruction = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
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
                deliverKeyboardResult(text: nil, error: nil)
                transcribingStartedAt = nil
                status = .ready
                recordingMode = .dictation
                autoStartedRecordingActive = false
                return
            }
            let result = try await AppleFoundationAssist.transform(
                text: originalText,
                instruction: instruction
            )
            guard generation == processingGeneration else { return }
            transcript = result
            deliverKeyboardResult(text: result, error: nil)
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

            autoStartedRecordingActive = false

            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            // Keep the user's original text on failure — they spoke
            // an instruction expecting a transformation; reverting to
            // raw would lose their intent and confuse the rollback.
            transcript = originalText
            transcriptSelection = nil
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            deliverKeyboardResult(text: nil, error: error.localizedDescription)
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            autoStartedRecordingActive = false
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
        #if DEBUG
        if isMorphPreview { return }
        #endif
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
            // Gate on a fresh disk probe. The downloader's `.completed`
            // state can outlive the actual files — a stale `.completed`
            // from a previous run, a different model variant, or the
            // simulator's storage being wiped between launches all
            // produced the bug where `modelDiskStatus = .downloaded`
            // but `ParakeetService.modelsExist` returned false. The
            // onboarding sheet's `firstPendingKind` reads `modelsExist`
            // directly (live), so it kept showing step 2 active while
            // the view model said `.downloaded`, and tapping the CTA
            // routed into `confirmAndDownloadModel`'s "already in
            // downloaded — ignoring tap" guard. Trust the disk, not the
            // downloader's last-known state.
            if ParakeetService.modelsExist(id: selectedModelID) {
                modelDiskStatus = .downloaded
            } else {
                NSLog("[Dictator iOS] downloader reports .completed but files for \(selectedModelID) are missing — resetting state")
                modelDiskStatus = .notDownloaded
            }
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

    /// The deterministic + optional-AI post-transcription pipeline, shared by
    /// dictation and the Scratchpad mic so both treat spoken cues, custom
    /// vocabulary, and filler-word cleanup identically.
    ///
    /// SpokenCues handles all the deterministic substitutions —
    /// punctuation/number/time/currency/emoji passes that the macOS app runs
    /// out of the box. Then Vocabulary runs LAST so a user's custom entry can
    /// override anything SpokenCues produced (e.g. mapping "fire emoji" to a
    /// wildfire alert text instead of 🔥). tidyDelivery cleans up the stray
    /// soft punctuation Whisper sometimes leaves around emojis. The optional
    /// Apple-Intelligence filler-word cleanup runs AFTER the deterministic
    /// substitutions so the model sees cue-resolved text; failures swallow
    /// silently — the user already has a working transcript and we don't want
    /// a cleanup hiccup to error out the whole recording.
    private func processTranscript(_ raw: String) async -> String {
        // Nothing said. Don't hand an empty string to the Apple model —
        // it has nothing to tidy and can take seconds to say so.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var processed = SpokenCues.apply(to: raw, options: DictatorIOSSettings.cueOptions)
        processed = Vocabulary.apply(VocabularyStore.shared.entries, to: processed)
        processed = SpokenCues.tidyDelivery(processed)
        if UserDefaults.standard.bool(forKey: DictatorIOSSettings.foundationCleanupKey) {
            do {
                processed = try await AppleFoundationCleanup.tidy(processed)
            } catch {
                NSLog("[DictatorIOS] Foundation cleanup skipped: \(error.localizedDescription)")
            }
        }
        return processed
    }

    // MARK: - Entry editor capture

    /// Where an entry-editor capture delivers: the text to insert, or the
    /// reworded replacement. Set at start, cleared once called.
    private var entryCompletion: ((String) -> Void)?
    /// The text an entry Reword applies to.
    private var entryAssistSource = ""

    /// Start dictating into the journal's entry editor. `assistSource` makes
    /// it a Reword: the speech becomes an instruction applied to that text.
    func startEntryCapture(assistSource: String? = nil, onResult: @escaping (String) -> Void) {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        if assistSource != nil, !AppleFoundationAssist.isAvailable { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = assistSource == nil ? .entry : .entryAssist
            entryAssistSource = assistSource ?? ""
            entryCompletion = onResult
            recordingStartCount &+= 1
            lastTranscriptionDuration = nil
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            beginCapture()
        default:
            return
        }
    }

    func stopEntryCapture() async {
        await runProcessing { await self.stopEntryCaptureWork() }
    }

    private func stopEntryCaptureWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        let isAssist = recordingMode == .entryAssist
        let deliver = entryCompletion
        entryCompletion = nil
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            if isAssist {
                // Cues resolved, vocabulary skipped — it's an instruction,
                // not words for the page. Same as the Scratchpad's Reword.
                let instruction = SpokenCues.apply(to: raw, options: DictatorIOSSettings.cueOptions)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let source = entryAssistSource
                if !instruction.isEmpty, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let result = try await AppleFoundationAssist.transform(text: source, instruction: instruction)
                    guard generation == processingGeneration else { return }
                    deliver?(result)
                    UsageStatsStore.shared.record(
                        mode: .assistant,
                        wordsIn: UsageStatsStore.wordCount(instruction),
                        wordsOut: UsageStatsStore.wordCount(result)
                    )
                }
            } else {
                let processed = await processTranscript(raw)
                guard generation == processingGeneration else { return }
                if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    deliver?(processed)
                    DictationHistoryStore.shared.append(processed, raw: raw, mode: .dictation)
                    UsageStatsStore.shared.record(
                        mode: .dictation,
                        wordsIn: UsageStatsStore.wordCount(raw),
                        wordsOut: UsageStatsStore.wordCount(processed)
                    )
                }
            }
            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
        }
        entryAssistSource = ""
        recordingMode = .dictation
    }

    /// The editor closed mid-capture: keep nothing, release the mic.
    func cancelEntryCapture() {
        guard recordingMode == .entry || recordingMode == .entryAssist else { return }
        entryCompletion = nil
        entryAssistSource = ""
        if status.isCapturing {
            _ = recorder.stop()
            status = .idle
            recordingMode = .dictation
        }
    }

    /// Hold-to-talk / tap-to-toggle handler for the Scratchpad tab's mic.
    /// Records into the synced note rather than the transcript editor — same
    /// engine, same prewarm, different destination. The transcript field is
    /// left untouched so a dictation in progress on the Dictation tab isn't
    /// disturbed by jotting into the Scratchpad.
    func startScratchpadRecording() {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = .scratchpad
            recordingStartCount &+= 1
            lastTranscriptionDuration = nil
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            beginCapture()
        default:
            return
        }
    }

    /// Counterpart to `startScratchpadRecording`. Drains the recorder,
    /// transcribes, runs the shared post-processing, then merges the result
    /// into `ScratchpadModel.shared` at the note's caret / selection (via the
    /// shared `TranscriptMerge`, same as the Dictation transcript), autosaves,
    /// and records a history + usage entry.
    func stopScratchpadRecording() async {
        await runProcessing { await self.stopScratchpadRecordingWork() }
    }

    private func stopScratchpadRecordingWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            let processed = await processTranscript(raw)
            guard generation == processingGeneration else { return }
            let pad = ScratchpadModel.shared
            pad.ensureLoaded()
            pad.snapshotForUndo()
            pad.revealCaretOnNextUpdate = true   // gently scroll to the new text
            let merged = TranscriptMerge.insert(processed, into: pad.text, at: pad.selection)
            pad.text = merged.text
            pad.selection = merged.selection
            pad.scheduleSave()
            DictationHistoryStore.shared.append(processed, raw: raw, mode: .dictation)
            UsageStatsStore.shared.record(
                mode: .dictation,
                wordsIn: UsageStatsStore.wordCount(raw),
                wordsOut: UsageStatsStore.wordCount(processed)
            )
            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
        }
        recordingMode = .dictation
    }

    /// The Journal tab's mic. Same capture and post-processing as a
    /// dictation; the destination is today's journal file.
    func startJournalRecording() {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = .journal
            recordingStartCount &+= 1
            lastTranscriptionDuration = nil
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            beginCapture()
        default:
            return
        }
    }

    func stopJournalRecording() async {
        await runProcessing { await self.stopJournalRecordingWork() }
    }

    private func stopJournalRecordingWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            let processed = await processTranscript(raw)
            // Cancelled while it was being written down: keep nothing.
            guard generation == processingGeneration else { return }
            if !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try await JournalModel.shared.add(processed)
                } catch {
                    UIPasteboard.general.string = processed
                    throw error
                }
                DictationHistoryStore.shared.append(processed, raw: raw, mode: .dictation)
                UsageStatsStore.shared.record(
                    mode: .dictation,
                    wordsIn: UsageStatsStore.wordCount(raw),
                    wordsOut: UsageStatsStore.wordCount(processed)
                )
            }
            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
        }
        recordingMode = .dictation
    }

    /// Hold-to-talk handler for the Scratchpad tab's assist button — a spoken
    /// instruction transforms the note. No-op if there's nothing to transform
    /// (empty note) or Apple Intelligence isn't available. The UI gates this
    /// too, but the guards cover races.
    func startScratchpadAssist() {
        guard permission == .granted else { return }
        guard case .downloaded = modelDiskStatus else { return }
        guard AppleFoundationAssist.isAvailable else { return }
        guard !ScratchpadModel.shared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch status {
        case .idle, .ready, .error:
            recordingMode = .scratchpadAssist
            recordingStartCount &+= 1
            lastTranscriptionDuration = nil
            status = .warmingUp
            pressFeedback.impactOccurred()
            prewarmModelIfNeeded()
            beginCapture()
        default:
            return
        }
    }

    /// Counterpart to `startScratchpadAssist`. Transcribes the spoken
    /// instruction, then feeds it to Apple Foundation Models with the target
    /// text — the selected range when there is one (replaced in place), or the
    /// whole note otherwise. Mirrors the Dictation assist flow but scoped to
    /// the selection so you can reword just a paragraph.
    func stopScratchpadAssist() async {
        await runProcessing { await self.stopScratchpadAssistWork() }
    }

    private func stopScratchpadAssistWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        let pad = ScratchpadModel.shared
        pad.ensureLoaded()
        let fullText = pad.text
        let sel = pad.selection
        let hasSelection = (sel?.length ?? 0) > 0 && (sel!.location + sel!.length) <= (fullText as NSString).length
        let targetText = hasSelection ? (fullText as NSString).substring(with: sel!) : fullText
        do {
            let rawInstruction = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            // Resolve spoken cues in the instruction (so "comma" etc. read as
            // glyphs) but skip Vocabulary — that's for dictated output, not
            // transform instructions. Matches the Dictation assist path.
            let instruction = SpokenCues.apply(to: rawInstruction, options: DictatorIOSSettings.cueOptions)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty, !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                transcribingStartedAt = nil
                status = .ready
                recordingMode = .dictation
                return
            }
            let result = try await AppleFoundationAssist.transform(text: targetText, instruction: instruction)
            guard generation == processingGeneration else { return }
            pad.snapshotForUndo()
            pad.revealCaretOnNextUpdate = true   // gently scroll to the reworded text
            if hasSelection {
                pad.text = (fullText as NSString).replacingCharacters(in: sel!, with: result)
                // Keep the transformed text selected so it's easy to re-assist.
                pad.selection = NSRange(location: sel!.location, length: (result as NSString).length)
            } else {
                pad.text = result
                pad.selection = nil
            }
            pad.scheduleSave()
            DictationHistoryStore.shared.append(pad.text, raw: targetText, mode: .assist)
            UsageStatsStore.shared.record(
                mode: .assistant,
                wordsIn: UsageStatsStore.wordCount(instruction),
                wordsOut: UsageStatsStore.wordCount(result)
            )
            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
        }
        recordingMode = .dictation
    }

    /// Called when the user releases the mic button. Drains the recorder,
    /// awaits the (possibly already-running) model load via transcribe's
    /// internal ensureLoaded, runs the samples through Parakeet, applies
    /// vocabulary substitution, and persists to history.
    func stopRecording() async {
        await runProcessing { await self.stopRecordingWork() }
    }

    private func stopRecordingWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        if isKeyboardCapture { return await stopKeyboardCapture() }
        guard let samples = await drainRecorder() else { return }
        pressFeedback.impactOccurred()
        guard !samples.isEmpty else {
            deliverKeyboardResult(text: nil, error: nil)
            status = .idle
            autoStartedRecordingActive = false
            return
        }

        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()

        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
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
            let processed = await processTranscript(raw)
            guard generation == processingGeneration else { return }

            mergeTranscribed(processed)
            deliverKeyboardResult(text: processed, error: nil)
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

            autoStartedRecordingActive = false

            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            status = .ready
            resultFeedback.notificationOccurred(.success)
        } catch {
            guard generation == processingGeneration else { return }
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            deliverKeyboardResult(text: nil, error: error.localizedDescription)
            status = .error(error.localizedDescription)
            resultFeedback.notificationOccurred(.error)
            autoStartedRecordingActive = false
        }
    }

    /// Bumped as each capture starts transcribing; `cancelProcessing`
    /// bumps it again, so the abandoned one sees it's stale when its next
    /// await returns and delivers nothing — the UI is back at rest at once,
    /// even while the cancelled work is still winding down.
    private var processingGeneration = 0

    /// The capture being transcribed, so a cancel can stop the work rather
    /// than just ignore it: FluidAudio checks for cancellation between
    /// decoder steps, and the Apple model stops generating. The model
    /// *load* isn't interrupted — the next recording needs it anyway.
    private var processingTask: Task<Void, Never>?

    /// Runs one stop-and-transcribe as its own task so `cancelProcessing`
    /// can cancel it. Waits for it, so callers still see it finish.
    private func runProcessing(_ work: @escaping @MainActor () async -> Void) async {
        let task = Task { @MainActor in await work() }
        processingTask = task
        await task.value
        if processingTask == task { processingTask = nil }
    }

    private func beginProcessing() -> Int {
        processingGeneration &+= 1
        return processingGeneration
    }

    /// Tapped while anything is "Transcribing…" / "Writing it down…" /
    /// rewording: drop it, whichever mode owns it. The audio is discarded
    /// and nothing is inserted, saved or handed to the keyboard.
    func cancelProcessing() {
        guard case .transcribing = status else { return }
        processingGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        transcribingStartedAt = nil
        deliverKeyboardResult(text: nil, error: nil)
        entryCompletion = nil
        entryAssistSource = ""
        keyboardSourceText = nil
        autoStartedRecordingActive = false
        status = .idle
        recordingMode = .dictation
        resultFeedback.notificationOccurred(.warning)
    }

    /// Abort a recording mid-flight without transcribing. Safe to
    /// call when nothing's recording (no-op on status).
    func cancelRecording() {
        if status.isCapturing {
            _ = recorder.stop()
            deliverKeyboardResult(text: nil, error: nil)
            status = .idle
            recordingMode = .dictation
            resultFeedback.notificationOccurred(.warning)
        }
        autoStartedRecordingActive = false
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
    func beginKeyboardRecording(mode: KeyboardBridge.Mode, surroundingText: String?, session request: UUID? = nil) {
        // A keyboard capture already running in the background (the user
        // tapped Dictate in the keyboard, then opened Dictator) owns the mic;
        // leave it be rather than start a second one over it.
        guard !status.isCapturing else { return }
        autoStartedRecordingActive = true
        // The keyboard waits on this id; the result is handed back to it
        // so returning to the original app inserts the text directly.
        servingID = request
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
            // The keyboard hands over the text the user highlighted.
            // With nothing highlighted it hands over nothing and we
            // read what they copied instead (the original route,
            // because `selectedText` once truncated long selections in
            // WebView-backed fields — Radar FB7789012). iOS fires the
            // "Pasted from X" toast on that read.
            transcript = surroundingText ?? UIPasteboard.general.string ?? ""
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

    // MARK: - Background session and keyboard commands

    /// Stop the recorder and wait for its samples at 16 kHz; the resample
    /// runs off the main actor so the morph back to rest doesn't stall.
    /// Nil if the recording was cancelled while that ran.
    private func drainRecorder() async -> [Float]? {
        isDrainingCapture = true
        defer { isDrainingCapture = false }
        let samples = await recorder.stop().resampled()
        guard status.isCapturing else { return nil }
        return samples
    }

    /// Every capture starts here, so the warm-or-not decision is made before
    /// the engine is armed: the audio-session category differs (a warm mic
    /// mixes with other audio instead of ducking it for minutes on end), and
    /// it can't be changed later without restarting the engine — which iOS
    /// won't allow from the background.
    private func beginCapture() {
        if !recorder.isArmed {
            recorder.keepWarm = BackgroundSession.shouldKeepWarm
        }
        recorder.start()
    }

    /// Mirror `status` into the session: keyboard heartbeat, Live Activity,
    /// screen-awake, background runway.
    private func syncBackgroundSession() {
        let phase: KeyboardBridge.SessionState.Phase? = switch status {
        case .warmingUp, .recording: .recording
        case .transcribing: .transcribing
        default: nil
        }
        let mode: KeyboardBridge.Mode? = switch recordingMode {
        case .assist, .scratchpadAssist, .keyboardAssist, .entryAssist: .assist
        default: .record
        }
        session.update(
            phase: phase,
            mode: phase == nil ? nil : mode,
            serving: servingID,
            warm: recorder.keepWarm && recorder.isArmed
        )
    }

    /// Release the warm mic and end the Live Activity.
    func endBackgroundSession() {
        if status.isCapturing {
            // Only reached via an explicit End; finish what was said first.
            recorder.keepWarm = false
            Task { await finishCurrentCapture() }
            return
        }
        recorder.keepWarm = false
        recorder.shutdown()
        session.stop()
    }

    /// True while the capture in flight belongs to the keyboard. Any of the
    /// in-app stop buttons then finish it the keyboard's way.
    private var isKeyboardCapture: Bool {
        recordingMode == .keyboard || recordingMode == .keyboardAssist
    }

    /// True while the keyboard can dictate without opening Dictator.
    var isBackgroundSessionLive: Bool {
        recorder.keepWarm && recorder.isArmed
    }

    /// Stop whatever is capturing, through the path that owns it.
    func finishCurrentCapture() async {
        guard status.isCapturing else { return }
        switch recordingMode {
        case .assist:           await stopAssistRecording()
        case .scratchpad:       await stopScratchpadRecording()
        case .scratchpadAssist: await stopScratchpadAssist()
        case .dictation:        await stopRecording()
        case .keyboard, .keyboardAssist: await stopKeyboardCapture()
        case .journal:          await stopJournalRecording()
        case .entry, .entryAssist: await stopEntryCapture()
        }
    }

    /// A phone call, Siri, or a route change took the mic. Keep what was
    /// said — `recorder.stop()` still returns it — and end the session,
    /// since a backgrounded app can't take the mic back.
    private func handleRecorderInterrupted() {
        recorder.keepWarm = false
        if status.isCapturing {
            Task { await finishCurrentCapture() }
        } else {
            session.stop()
        }
    }

    /// The keyboard sent a command through the App Group.
    private func handleKeyboardCommand() {
        guard let command = KeyboardBridge.takeCommand() else { return }
        switch command.action {
        case .start:
            startKeyboardCapture(id: command.id, mode: command.mode, sourceText: command.sourceText)
        case .stop:
            guard status.isCapturing, command.target == nil || command.target == servingID else { return }
            Task { await finishCurrentCapture() }
        case .cancel:
            guard command.target == nil || command.target == servingID else { return }
            if case .transcribing = status { cancelProcessing() } else { cancelRecording() }
        case .end:
            endBackgroundSession()
        }
    }

    /// The Live Activity's buttons.
    private func handleActivityCommand(_ command: DictationActivityCommand?) {
        switch command {
        case .toggle:
            if status.isCapturing {
                Task { await finishCurrentCapture() }
            } else {
                startKeyboardCapture(id: nil, mode: .record, sourceText: nil)
            }
        case .end:
            endBackgroundSession()
        case nil:
            break
        }
    }

    /// Record for the keyboard (or the Live Activity) while Dictator is in
    /// the background. Needs a warm mic, unless Dictator happens to be in
    /// front, where arming one is allowed.
    private func startKeyboardCapture(id: UUID?, mode: KeyboardBridge.Mode, sourceText: String?) {
        func refuse(_ message: String) {
            if let id { KeyboardBridge.writeResult(.init(serving: id, text: nil, error: message, createdAt: Date())) }
        }
        guard permission == .granted, case .downloaded = modelDiskStatus else {
            return refuse("Open Dictator to finish setting up.")
        }
        switch status {
        case .idle, .ready, .error: break
        default: return refuse("Dictator is busy. Try again in a moment.")
        }
        guard recorder.isArmed || UIApplication.shared.applicationState != .background else {
            return refuse("The microphone was turned off. Tap Dictate again to open Dictator.")
        }
        if mode == .assist {
            guard AppleFoundationAssist.isAvailable else { return refuse("Assist needs Apple Intelligence.") }
            guard let sourceText, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return refuse("Copy the text you want to change first.")
            }
        }
        servingID = id
        keyboardSourceText = sourceText
        recordingMode = mode == .assist ? .keyboardAssist : .keyboard
        recordingStartCount &+= 1
        lastTranscriptionDuration = nil
        status = .warmingUp
        prewarmModelIfNeeded()
        beginCapture()
    }

    /// Counterpart to `startKeyboardCapture`. The result goes to the keyboard
    /// and the clipboard, and into history — not into the transcript editor.
    private func stopKeyboardCapture() async {
        await runProcessing { await self.stopKeyboardCaptureWork() }
    }

    private func stopKeyboardCaptureWork() async {
        guard status.isCapturing, !isDrainingCapture else { return }
        let assist = recordingMode == .keyboardAssist
        guard let samples = await drainRecorder() else { return }
        guard !samples.isEmpty else {
            deliverKeyboardResult(text: nil, error: nil)
            status = .idle
            recordingMode = .dictation
            return
        }
        status = .transcribing
        transcribingStartedAt = Date()
        let generation = beginProcessing()
        do {
            let raw = try await parakeet.transcribe(samples: samples, modelID: selectedModelID)
            guard generation == processingGeneration else { return }
            if !isModelLoaded {
                isModelLoaded = true
                publishModelReadiness()
            }
            let output: String
            if assist {
                let instruction = SpokenCues.apply(to: raw, options: DictatorIOSSettings.cueOptions)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let source = keyboardSourceText ?? ""
                output = instruction.isEmpty
                    ? ""
                    : try await AppleFoundationAssist.transform(text: source, instruction: instruction)
                guard generation == processingGeneration else { return }
                if !output.isEmpty {
                    DictationHistoryStore.shared.append(output, raw: source, mode: .assist)
                    UsageStatsStore.shared.record(
                        mode: .assistant,
                        wordsIn: UsageStatsStore.wordCount(instruction),
                        wordsOut: UsageStatsStore.wordCount(output)
                    )
                }
            } else {
                output = await processTranscript(raw)
                guard generation == processingGeneration else { return }
                if !output.isEmpty {
                    DictationHistoryStore.shared.append(output, raw: raw, mode: .dictation)
                    UsageStatsStore.shared.record(
                        mode: .dictation,
                        wordsIn: UsageStatsStore.wordCount(raw),
                        wordsOut: UsageStatsStore.wordCount(output)
                    )
                }
            }
            if !output.isEmpty {
                // On the clipboard too, so the text is never lost if the
                // keyboard has gone by the time it's ready.
                UIPasteboard.general.string = output
                KeyboardBridge.writeLastDictation(.init(
                    text: output,
                    pasteboardChangeCount: UIPasteboard.general.changeCount,
                    writtenAt: Date()
                ))
                session.noteResult(output)
            }
            deliverKeyboardResult(text: output.isEmpty ? nil : output, error: nil)
            if let started = transcribingStartedAt {
                lastTranscriptionDuration = Date().timeIntervalSince(started)
            }
            transcribingStartedAt = nil
            keyboardSourceText = nil
            recordingMode = .dictation
            status = .ready
        } catch {
            guard generation == processingGeneration else { return }
            deliverKeyboardResult(text: nil, error: error.localizedDescription)
            transcribingStartedAt = nil
            lastTranscriptionDuration = nil
            keyboardSourceText = nil
            recordingMode = .dictation
            status = .error(error.localizedDescription)
        }
    }

    /// Hand a finished capture's outcome to the keyboard waiting on it, if
    /// one is. A nil text and nil error means "nothing was said" — the
    /// keyboard just returns to rest.
    private func deliverKeyboardResult(text: String?, error: String?) {
        guard let id = servingID else { return }
        servingID = nil
        KeyboardBridge.writeResult(.init(serving: id, text: text, error: error, createdAt: Date()))
    }

    /// Publish the model's disk + memory status to the App Group so
    /// the Dictator keyboard can render a "fast / slow / not yet
    /// downloaded" hint. Called at every lifecycle transition that
    /// touches model state. Cheap — single JSON encode + UserDefaults
    /// write, fires only on transitions, not in any hot path.
    ///
    /// Also republishes assist availability in the same breath. The
    /// keyboard can't link FoundationModels (memory ceiling + jetsam
    /// risk in the appex), so the host owns the availability check and
    /// hands the keyboard a plain boolean to gate its Assist button.
    /// Piggybacking on this method means availability stays fresh at
    /// exactly the points the keyboard cares about — launch and every
    /// foreground — without a second set of call sites to keep in sync.
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
        // `isAvailable` funnels through `AppleFoundationAssist.availability`,
        // which honours the DEBUG override and re-queries the live
        // `SystemLanguageModel` each call — so toggling Apple
        // Intelligence in iOS Settings is reflected on the next
        // foreground publish.
        KeyboardBridge.writeAssistAvailable(AppleFoundationAssist.isAvailable)
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

    /// Merge a freshly transcribed chunk into the transcript at the current
    /// selection/caret (or append). Delegates to the shared `TranscriptMerge`
    /// so the Dictation transcript and the Scratchpad note insert identically.
    private func mergeTranscribed(_ chunk: String) {
        let result = TranscriptMerge.insert(chunk, into: transcript, at: transcriptSelection)
        transcript = result.text
        transcriptSelection = result.selection
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
