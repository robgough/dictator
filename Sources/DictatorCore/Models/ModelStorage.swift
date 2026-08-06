import Foundation

enum ModelStorage {
    static func root() -> URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (base ?? fm.temporaryDirectory).appendingPathComponent("Dictator/Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func whisperRoot() -> URL {
        let dir = root().appendingPathComponent("whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func llmRoot() -> URL {
        let dir = root().appendingPathComponent("llm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func parakeetRoot() -> URL {
        let dir = root().appendingPathComponent("parakeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Snapshot directory for a downloaded LLM: `<llmRoot>/models/<repoID>/`.
    /// `HubApi(downloadBase:)` writes this layout, `ModelManager` reads it to
    /// drive the download UI, and `MLXLLMService` loads directly from it so
    /// that using an already-downloaded model never has to ask the Hub where
    /// its files are. Does not create the directory — callers test existence.
    static func llmModelDirectory(for repoID: String) -> URL {
        llmRoot().appendingPathComponent("models/\(repoID)", isDirectory: true)
    }

    /// Snapshot directory for a WhisperKit CoreML variant. WhisperKit always
    /// pulls these from the one repo, so the path is fixed apart from the
    /// variant. Passed to `WhisperKitConfig.modelFolder` to keep loads local.
    static func whisperModelDirectory(for variant: String) -> URL {
        whisperRoot()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// Hub's part-file metadata for a Whisper variant. Unlike the LLM layout
    /// (where it sits *inside* the snapshot) this is a sibling of the variant
    /// folders, so it needs its own accessor.
    static func whisperDownloadMetadataDirectory(for variant: String) -> URL {
        whisperRoot()
            .appendingPathComponent(
                "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(variant)",
                isDirectory: true)
    }

    /// Hub's part-file metadata for an LLM snapshot, which Hub nests inside the
    /// snapshot directory itself.
    static func llmDownloadMetadataDirectory(for repoID: String) -> URL {
        llmModelDirectory(for: repoID)
            .appendingPathComponent(".cache/huggingface/download", isDirectory: true)
    }

    /// True when `snapshot` holds a *finished* Hub download: nothing still
    /// downloading (no `*.incomplete` part-files under `metadata`) and a
    /// snapshot whose contents satisfy `isReady`.
    ///
    /// The engines call this to decide whether they can load purely from disk
    /// and skip the Hub. `ModelManager.diskState` applies the same two rules
    /// for the Settings download UI but stays separate — it also needs a
    /// resume percentage, which callers here don't.
    ///
    /// Being wrong in the optimistic direction is survivable: both load paths
    /// fall back to the Hub if the local load actually throws.
    static func downloadIsComplete(
        snapshot: URL,
        metadata: URL,
        isReady: ([String]) -> Bool
    ) -> Bool {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: metadata, includingPropertiesForKeys: nil,
                                          options: [], errorHandler: nil) {
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
                return false
            }
        }
        guard fm.fileExists(atPath: snapshot.path) else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
        return isReady(contents)
    }

    /// FluidAudio's `OfflineDiarizerModels.load(from:)` treats this URL as the
    /// parent dir and appends `Repo.diarizer.folderName` ("speaker-diarization")
    /// itself, so the actual weights land at
    /// `~/Library/Application Support/Dictator/Models/diarization/speaker-diarization/…`.
    static func diarizationRoot() -> URL {
        let dir = root().appendingPathComponent("diarization", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
