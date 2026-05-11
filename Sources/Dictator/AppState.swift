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

    private init() {
        let settings = DictatorSettings.load()
        self.settings = settings
        self.pipeline = Pipeline(settings: settings)
    }

    func bootstrap() {
        AudioDeviceManager.shared.bootstrap()
        pipeline.onAssistantResultCopied = { [weak self] text, instruction in
            self?.assistantResultWindow.show(text: text, instruction: instruction)
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
    }

    /// Warm both Whisper and the LLM in the background so the first hotkey press
    /// doesn't pay for model load. Only models that are already on disk are loaded —
    /// we don't silently kick off a multi-GB download at launch.
    func preloadModels() {
        let whisperID = settings.whisperModelID
        let llmID = settings.llmModelID
        let manager = ModelManager.shared
        manager.refreshCachedStates()

        if manager.whisperStates[whisperID] == .ready {
            Task { try? await TranscriptionServiceHolder.shared.ensureLoaded(modelID: whisperID) }
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
