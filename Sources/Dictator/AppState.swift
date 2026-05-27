import Foundation
import MLX
import Observation
import SwiftUI

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

    private let dictationHotkey = HotkeyBinder(shortcutName: .toggleDictation)
    private let assistantHotkey = HotkeyBinder(shortcutName: .toggleAssistant)
    private let assistantResultWindow = AssistantResultController()
    private var onboardingController: OnboardingController?

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
            onRelease: { [weak self] in self?.pipeline.finishRecording() }
        )
        assistantHotkey.bind(
            mode: settings.assistantTriggerMode,
            onPress: { [weak self] in self?.pipeline.startAssistant() },
            onRelease: { [weak self] in self?.pipeline.finishAssistant() }
        )
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
    }

    /// Used by the Settings UI's "Reset" button next to the keyboard-shortcut recorder.
    func resetDictationKeyboardShortcut() {
        dictationHotkey.resetKeyboardShortcutToDefault()
    }

    func resetAssistantKeyboardShortcut() {
        assistantHotkey.resetKeyboardShortcutToDefault()
    }
}
