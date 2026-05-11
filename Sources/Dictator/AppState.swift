import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var settings: DictatorSettings
    let pipeline: Pipeline

    private init() {
        let settings = DictatorSettings.load()
        self.settings = settings
        self.pipeline = Pipeline(settings: settings)
    }

    func bootstrap() {
        AudioDeviceManager.shared.bootstrap()
        HotkeyBinder.shared.bind(
            mode: settings.triggerMode,
            onPress: { [weak self] in self?.pipeline.startRecording() },
            onRelease: { [weak self] in self?.pipeline.finishRecording() }
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
        HotkeyBinder.shared.setMode(settings.triggerMode)
    }
}
