import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var settings: DictatorSettings
    let pipeline: Pipeline

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
        AudioDeviceManager.shared.bootstrap()
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
    /// download at launch.
    func preloadModels() {
        let llmID = settings.llmModelID
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
        if llmID != ModelCatalog.noneLLMID, manager.llmStates[llmID] == .ready {
            Task { try? await LLMServiceHolder.shared.ensureLoaded(modelID: llmID) }
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
