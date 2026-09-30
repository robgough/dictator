import AppKit
import Foundation

/// Moving people off a superseded language model, and cleaning up after.
///
/// Legacy models stay in the catalog so an update never breaks anyone
/// (`LLMModel.isLegacy`), but nothing told their users there was something
/// better — the "Superseded by …" note only shows in Settings → Models. This
/// says so twice: once as a launch alert, and for as long as it applies as a
/// line in the menu bar, where "Switch" downloads the replacement if needed and
/// then selects it. Once they've moved, the old weights are offered for
/// deletion from the same place.
@MainActor
@Observable
final class LegacyModelUpgrade {
    static let shared = LegacyModelUpgrade()

    /// The replacement currently downloading on the way to a switch.
    private(set) var pendingID: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    private init() {}

    /// The legacy model in use and what replaced it, when the MLX engine is on
    /// a superseded model.
    func offer(for settings: DictatorSettings) -> (old: LLMModel, new: LLMModel)? {
        guard settings.llmEngine == .mlx,
              let old = ModelCatalog.llm(id: settings.llmModelID), old.isLegacy,
              let new = ModelCatalog.replacement(forLegacy: old.id)
        else { return nil }
        return (old, new)
    }

    /// Legacy models still on disk that nothing uses: not Dictator's model, and
    /// not the one Dictator Meetings is set to run itself.
    func leftovers(for settings: DictatorSettings) -> [LLMModel] {
        let meetingsModel = Self.meetingsLocalModelID()
        return ModelCatalog.llmModels.filter { model in
            model.isLegacy
                && model.id != settings.llmModelID
                && model.id != meetingsModel
                && ModelManager.shared.llmStates[model.id] == .ready
        }
    }

    /// Selects the replacement, downloading it first if it isn't on disk.
    func switchToReplacement(state: AppState) {
        guard let offer = offer(for: state.settings) else { return }
        let manager = ModelManager.shared
        if manager.llmStates[offer.new.id] == .ready {
            apply(offer.new.id, replacing: offer.old.id, state: state)
            return
        }
        manager.downloadLLM(offer.new.id, using: MLXLLMServiceHolder.shared)
        pendingID = offer.new.id
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            // Downloads report through `llmStates`; wait for it to land.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                switch manager.llmStates[offer.new.id] {
                case .ready?:
                    self?.pendingID = nil
                    // Only if they're still on the model this was offered for:
                    // picking something else in the meantime wins.
                    if state.settings.llmModelID == offer.old.id {
                        self?.apply(offer.new.id, replacing: offer.old.id, state: state)
                    }
                    return
                case .failed?, .notDownloaded?, .partial?:
                    // Failed or cancelled from Settings: the row falls back
                    // to offering the switch again.
                    self?.pendingID = nil
                    return
                default:
                    continue
                }
            }
        }
    }

    func delete(_ model: LLMModel) {
        _ = ModelManager.shared.removeLLM(model.id, using: MLXLLMServiceHolder.shared)
    }

    private func apply(_ newID: String, replacing oldID: String, state: AppState) {
        state.settings.llmModelID = newID
        state.save()
        // Free the old weights' memory now rather than holding two models, and
        // warm the new one so the next dictation doesn't pay for the load.
        MLXLLMServiceHolder.shared.unload(modelID: oldID)
        Task { try? await MLXLLMServiceHolder.shared.ensureLoaded(modelID: newID) }
    }

    // MARK: - Launch alert

    private static func noticeKey(_ id: String) -> String { "LegacyModelNoticeShown.\(id)" }

    /// Once per legacy model per Mac: a modal saying it's been superseded, with
    /// the switch one click away. Per-Mac (UserDefaults) because the model
    /// choice is per-Mac.
    func showLaunchNoticeIfNeeded(state: AppState) {
        guard !ScreenshotMode.isActive,
              let offer = offer(for: state.settings),
              !UserDefaults.standard.bool(forKey: Self.noticeKey(offer.old.id))
        else { return }
        UserDefaults.standard.set(true, forKey: Self.noticeKey(offer.old.id))

        let needsDownload = ModelManager.shared.llmStates[offer.new.id] != .ready
        let alert = NSAlert()
        alert.messageText = "\(offer.old.displayName) has been replaced"
        alert.informativeText = """
            Dictator's formatting is now tuned for \(offer.new.displayName), a newer model \
            of the same size. Your current model still works, but you'll get better results \
            from the new one.\(needsDownload ? " Switching downloads about \(formatModelSize(offer.new.approxSizeMB))." : "")

            You can also switch later from the menu bar, and remove the old model there afterwards.
            """
        alert.addButton(withTitle: needsDownload ? "Download and Switch" : "Switch")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            switchToReplacement(state: state)
        }
    }

    // MARK: - Dictator Meetings' own model

    /// The model Dictator Meetings runs itself when it isn't borrowing
    /// Dictator's (`localLLMModelID` in its per-Mac settings). Read-only, and
    /// read fresh: Meetings is a separate app that may change it at any time.
    private static func meetingsLocalModelID() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dictator/meetings-local-settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any]
        else { return nil }
        return settings["localLLMModelID"] as? String
    }
}
