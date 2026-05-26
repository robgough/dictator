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
