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
        // Teach the shared `SyncedStorage` where this app's synced folder is.
        // It can't read `AppState` directly — the file is compiled into
        // Dictator Meetings and the iOS app too — so it asks through this closure.
        // Registered here rather than in `bootstrap()` because anything that
        // reaches `SyncedStorage.directory` has necessarily gone through
        // `AppState.shared` first.
        SyncedStorage.customDirectoryProvider = { AppState.shared.settings.syncedDirectoryPath }
        let settings = DictatorSettings.load()
        self.settings = settings
        self.pipeline = Pipeline(settings: settings)
    }

    func bootstrap() {
        MicLog.installUncaughtExceptionLogger()
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
        // Deliberately NOT reaping leaked aggregate tap devices here (Dictator
        // Meetings does that in its own bootstrap): destroying aggregate
        // devices interrupts whatever audio is playing, which is not a thing a
        // login-item menu-bar app should do. The leaked taps are already hidden
        // from the input list by the enumerator filter + knownDevices pruning.
        // Render + register the cue sounds off-main *now* so the first hotkey
        // press's arm chime is instant. Unlike the old engine prewarm this
        // opens no audio device IO (system sounds render inside coreaudiod),
        // so it can't dip other audio or pin the mic indicator — and there's
        // no point doing it when cues are switched off.
        SoundEffects.shared.setTheme(settings.soundTheme)
        if settings.playSounds { SoundEffects.shared.prewarm() }
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
            onCancel: { [weak self] in self?.pipeline.cancelInFlight() },
            tapToToggle: { [weak self] in self?.settings.hotkeyTapToToggleEnabled ?? false }
        )
        assistantHotkey.bind(
            mode: settings.assistantTriggerMode,
            onPress: { [weak self] in self?.pipeline.startAssistant() },
            onRelease: { [weak self] in self?.pipeline.finishAssistant() },
            onCancel: { [weak self] in self?.pipeline.cancelInFlight() },
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
        // Publish the loaded LLM for Dictator Meetings to borrow. Deferred into
        // a Task so the listener setup (directory chmod, stale-socket unlink,
        // bind) never sits on the launch path — and so it lands after the
        // preload above has been kicked off, which is what makes the socket
        // worth connecting to in the first place.
        Task { @MainActor in
            LocalLLMServer.shared.applySettings(self.settings)
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
        SoundEffects.shared.setTheme(settings.soundTheme)
        // Start / stop the LLM socket to match the toggle. Idempotent, so
        // calling it on every save is cheap.
        LocalLLMServer.shared.applySettings(settings)
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
