import Foundation
import MLX
import Observation
import SwiftUI
import KeyboardShortcuts

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var settings: DictatorSettings
    let pipeline: Pipeline

    /// Captured `EnvironmentValues.openSettings` action, populated by the
    /// SwiftUI tree the first time MenuBarContent's body runs. Stored here
    /// so non-SwiftUI surfaces (the AppDelegate's URL handler, scripts
    /// triggering `dictator://settings`) can open Settings without
    /// SwiftUI's "use SettingsLink" runtime fault. Optional because the
    /// menu-bar popover may not have rendered yet on a cold launch.
    var openSettingsAction: (@MainActor () -> Void)?

    /// Captured `EnvironmentValues.openWindow` action so non-SwiftUI
    /// surfaces (dictator://meetings URL handler) can open the Meetings
    /// window. Set by MenuBarContent on first render.
    var openMeetingsAction: (@MainActor () -> Void)?

    /// One-shot flag set by the menu bar's "Record meeting" entry. Read
    /// (and immediately cleared) by `MeetingsRootView` the next time it
    /// appears or observes a change — at which point it kicks off the
    /// same `startRecording()` flow as the in-window Record button. The
    /// flag dodges the "window doesn't exist yet" race: the menu bar
    /// sets it *then* opens the window, so by the time the Meetings view
    /// renders it can observe the request and consume it in one place.
    var pendingMeetingRecording: Bool = false

    /// When a meeting is actively recording, the moment it started — mirrored
    /// from the live `MeetingSession` so the always-visible menu-bar icon can
    /// show a recording indicator even when the Meetings window is closed or
    /// backgrounded. nil when no meeting is recording.
    var meetingRecordingStartedAt: Date?
    var isRecordingMeeting: Bool { meetingRecordingStartedAt != nil }

    /// True while the Meetings window is the key window. Set by
    /// `MeetingsRootView` from its `controlActiveState`. Drives both the
    /// assistant-hotkey routing (below) and the "Hold ⌘⌥A to ask" affordance
    /// on the notes view, which only makes sense when the window is focused.
    var meetingsWindowIsKey: Bool = false

    /// The assistant controller for the meeting currently shown in the detail
    /// pane, registered by the notes view while it's on screen. Lets the
    /// assistant hotkey operate on the meeting's notes instead of the global
    /// selection when the Meetings window is focused. Weak + observation-
    /// ignored: it's a routing target, never rendered from here.
    @ObservationIgnored weak var meetingAssistant: MeetingAssistantController?
    /// Remembers which path the in-flight assistant press took, so the matching
    /// release goes to the same place even with tap-to-toggle (where the start
    /// and stop are seconds and a focus-change apart).
    @ObservationIgnored private weak var inFlightMeetingAssistant: MeetingAssistantController?

    /// The meeting assistant the hotkey should drive right now — only when the
    /// Meetings window is key and it actually has notes to act on. Otherwise
    /// nil, so the hotkey falls through to the normal selection-based assistant.
    /// Human-readable form of the assistant hotkey, for on-screen hints like
    /// "Hold ⌘⌥A to ask". Uses the live keyboard-combo when that mode is set,
    /// otherwise the modifier-key label.
    var assistantHotkeyDisplay: String {
        if settings.assistantTriggerMode == .keyboardShortcut {
            let s = KeyboardShortcuts.getShortcut(for: .toggleAssistant)?
                .description.trimmingCharacters(in: .whitespaces)
            return (s?.isEmpty == false) ? s! : "⌘⌥A"
        }
        return settings.assistantTriggerMode.label
    }

    private func routableMeetingAssistant() -> MeetingAssistantController? {
        guard meetingsWindowIsKey, let controller = meetingAssistant, controller.canRun else { return nil }
        return controller
    }

    /// Assistant-hotkey press. Routes to the focused meeting's notes assistant
    /// when one is available, else the global Assistant Mode flow.
    private func assistantPress() {
        if let controller = routableMeetingAssistant() {
            inFlightMeetingAssistant = controller
            controller.beginListening()
        } else {
            inFlightMeetingAssistant = nil
            pipeline.startAssistant()
        }
    }

    /// Assistant-hotkey release. Mirrors whatever `assistantPress` routed to.
    private func assistantRelease() {
        if let controller = inFlightMeetingAssistant {
            inFlightMeetingAssistant = nil
            controller.endListeningAndRun()
        } else {
            pipeline.finishAssistant()
        }
    }

    private let dictationHotkey = HotkeyBinder(shortcutName: .toggleDictation)
    private let assistantHotkey = HotkeyBinder(shortcutName: .toggleAssistant)
    private let assistantResultWindow = AssistantResultController()
    private var onboardingController: OnboardingController?

    /// The Scratchpad's panel controller. Created and injected by `AppDelegate`
    /// (alongside the HUD) before `bootstrap()` runs, so the toggle hotkey bound
    /// there has something to drive. Observation-ignored — it's a UI handle, not
    /// rendered from here.
    @ObservationIgnored var scratchpadController: ScratchpadController?

    private init() {
        let settings = DictatorSettings.load()
        self.settings = settings
        self.pipeline = Pipeline(settings: settings)
    }

    func bootstrap() {
        // Bound MLX's GPU buffer cache. The default `cacheLimit` mirrors
        // `memoryLimit`, which on systems with abundant RAM (32+ GB) lets
        // the buffer pool grow to many GB across repeated inferences as
        // different-sized intermediate buffers accumulate. We've seen
        // phys_footprint creep into the tens of GB on a 64 GB Mac after
        // a session of dictation. 512 MB is comfortably larger than any
        // single inference buffer the models we ship would allocate
        // (KV cache + activations), so steady-state cache-hit rate stays
        // high, but the pool can't run away.
        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

        // Move dictation history and conversations from their legacy App
        // Support location into the user's synced folder if they haven't
        // already migrated. Idempotent: subsequent launches no-op once the
        // synced copy exists. Runs before the singletons are first
        // referenced (DictationHistory.shared / ConversationHistory.shared)
        // so they pick up the synced location on initial load.
        SyncedStorage.migrateFromAppSupport(filename: "history.json")
        SyncedStorage.migrateFromAppSupport(filename: "conversations.json")
        SyncedStorage.cleanupLegacyBackups()

        // Meeting notes + transcripts live in the synced folder so a meeting
        // recorded on one Mac can be read on another; the large audio tracks
        // stay per-Mac in Application Support. Point MeetingStorage at the
        // synced folder, then reconcile on-disk meetings to that split (pulling
        // any audio that an earlier build synced back out to local). Must run
        // before MeetingsStore.shared is first referenced so its initial scan
        // reads the synced location.
        MeetingStorage.syncedBaseURL = SyncedStorage.directory
        MeetingStorage.migrateToSplitStorage()

        // VocabularyStore must boot before anything reads vocab. On a
        // pre-VocabularyStore install we hand it the legacy
        // settings.vocabulary array as a one-shot migration source; once
        // it's flushed to disk we clear the array on the in-memory
        // settings so a future save doesn't keep re-writing it.
        let customVocabDirectory = settings.syncedDirectoryPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let legacyVocab = settings.vocabulary
        VocabularyStore.shared.bootstrap(customDirectory: customVocabDirectory, legacyEntries: legacyVocab)
        if !legacyVocab.isEmpty {
            settings.vocabulary = []
            save()
        }

        AudioDeviceManager.shared.bootstrap()
        // Bring the audio cue engine up off-main *now* so the first
        // hotkey press doesn't pay first-touch start latency for the arm
        // chime. Best-effort — if the engine refuses to start (no output
        // device, weird state) the user just misses cues until the next
        // output-device configuration change retries.
        SoundEffects.shared.prewarm()
        pipeline.onAssistantTurnCompleted = { [weak self] conversation, surface in
            self?.assistantResultWindow.showConversation(id: conversation.id, surface: surface)
        }
        pipeline.resultWindowIsVisible = { [weak self] in
            self?.assistantResultWindow.isWindowVisible ?? false
        }
        pipeline.resultWindowConversationID = { [weak self] in
            self?.assistantResultWindow.currentConversationID
        }
        assistantResultWindow.onWindowClosed = { [weak self] in
            self?.pipeline.endActiveConversation()
        }
        assistantResultWindow.onConversationDisplayed = { [weak self] id in
            // When the user reopens a past conversation from the menu bar,
            // make it the active one so the next assistant call continues it.
            if let convo = ConversationHistory.shared.conversation(id: id) {
                self?.pipeline.setActiveConversation(convo)
            }
        }
        dictationHotkey.bind(
            mode: settings.triggerMode,
            onPress: { [weak self] in self?.pipeline.startRecording() },
            onRelease: { [weak self] in self?.pipeline.finishRecording() },
            tapToToggle: { [weak self] in self?.settings.hotkeyTapToToggleEnabled ?? false }
        )
        assistantHotkey.bind(
            mode: settings.assistantTriggerMode,
            onPress: { [weak self] in self?.assistantPress() },
            onRelease: { [weak self] in self?.assistantRelease() },
            tapToToggle: { [weak self] in self?.settings.hotkeyTapToToggleEnabled ?? false }
        )
        // Scratchpad: a plain tap-to-toggle combo, no push-to-talk semantics, so
        // it binds directly through KeyboardShortcuts rather than a HotkeyBinder.
        // The handler is registered once and checks the enable flag live, so the
        // Settings toggle takes effect without re-binding.
        KeyboardShortcuts.onKeyDown(for: .toggleScratchpad) { [weak self] in
            guard let self, self.settings.scratchpadEnabled else { return }
            self.scratchpadController?.toggle()
        }
        if settings.preloadModelsOnLaunch {
            preloadModels()
        }
        if !settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Show the first-run wizard. Called automatically at launch when the
    /// user hasn't completed onboarding yet, and from the menu bar's
    /// "Setup…" entry on demand. The flag is flipped to true regardless of
    /// whether the user finishes or skips — they can reopen the wizard any
    /// time, and we don't want it ambushing them on every launch.
    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingController(appState: self) { [weak self] in
                guard let self else { return }
                self.settings.hasCompletedOnboarding = true
                self.save()
            }
        }
        onboardingController?.show()
    }

    /// Opens a past conversation in the result window. Called from the menu
    /// bar's recent-conversations list.
    func openConversation(id: UUID) {
        assistantResultWindow.showConversation(id: id, surface: true)
    }

    /// Warm the active transcription engine + the LLM in the background so the
    /// first hotkey press doesn't pay for model load. Only models that are
    /// already on disk are loaded — we don't silently kick off a multi-GB
    /// download at launch. Apple Foundation Models is system-resident with
    /// no in-process load step, so there's nothing to preload for that engine.
    func preloadModels() {
        let manager = ModelManager.shared
        manager.refreshCachedStates()

        switch settings.transcriptionEngine {
        case .whisper:
            let id = settings.whisperModelID
            if manager.whisperStates[id] == .ready {
                Task { try? await TranscriptionServiceHolder.shared.ensureLoaded(modelID: id) }
            }
        case .parakeet:
            let id = settings.parakeetModelID
            if manager.parakeetStates[id] == .ready {
                Task { try? await ParakeetServiceHolder.shared.ensureLoaded(modelID: id) }
            }
        }
        if settings.llmEngine == .mlx, manager.llmStates[settings.llmModelID] == .ready {
            Task { try? await MLXLLMServiceHolder.shared.ensureLoaded(modelID: settings.llmModelID) }
        }
    }

    func save() {
        settings.persist()
        pipeline.settingsChanged(settings)
        dictationHotkey.setMode(settings.triggerMode)
        assistantHotkey.setMode(settings.assistantTriggerMode)
        // Keep meetings pointed at the (possibly just-changed) synced folder so
        // new recordings land there. Existing meetings aren't auto-moved on a
        // folder change — only the initial Application Support migration moves
        // them — so a relocate leaves prior meetings where they were.
        MeetingStorage.syncedBaseURL = SyncedStorage.directory
    }

    /// Used by the Settings UI's "Reset" button next to the keyboard-shortcut recorder.
    func resetDictationKeyboardShortcut() {
        dictationHotkey.resetKeyboardShortcutToDefault()
    }

    func resetAssistantKeyboardShortcut() {
        assistantHotkey.resetKeyboardShortcutToDefault()
    }
}
