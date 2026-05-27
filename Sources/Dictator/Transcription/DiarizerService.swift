import Foundation
@preconcurrency import CoreML
@preconcurrency import FluidAudio

/// Speaker diarization for the meetings pipeline. Mirrors `ParakeetService`
/// in shape (download / ensureLoaded / unload / one operation method) so the
/// Models pane can render its row without a special case.
///
/// FluidAudio's `OfflineDiarizerManager` is a single bundle in v0.2 — there
/// is no real "id" to choose between — but the `modelID` parameter exists so
/// future variants (e.g. an LS-EEND streaming bundle) can be selected by
/// catalogue id without rewriting callers.
///
/// Storage layout. `OfflineDiarizerModels.load(from:)` treats the supplied
/// URL as the parent directory and appends `Repo.diarizer.folderName`
/// ("speaker-diarization") itself, so the on-disk weights live at
/// `~/Library/Application Support/Dictator/Models/diarization/speaker-diarization/`.
@MainActor
@Observable
final class DiarizerService {
    /// ID of the model currently held in memory (nil when nothing loaded).
    private(set) var currentModelID: String?
    /// True while `ensureLoaded` or `download` is running. Drives spinners.
    private(set) var isLoading: Bool = false

    @ObservationIgnored private var manager: OfflineDiarizerManager?
    @ObservationIgnored private var loadedModelID: String?

    /// Clustering distance threshold passed to FluidAudio's
    /// `OfflineDiarizerConfig`. FluidAudio's default of 0.6 is tuned for
    /// clean studio audio (the pyannote community-1 benchmark suite);
    /// VoIP / video-call audio is heavily codec-compressed which pulls
    /// speaker embeddings closer together, causing the clusterer to merge
    /// distinct voices into one. 0.5 is empirically the right ballpark for
    /// Zoom/Meet/Teams audio — looser than studio defaults, but not so
    /// loose that the same speaker over-segments into "speaker_1" and
    /// "speaker_2". Exposed as a constant rather than a setting until we
    /// see whether one threshold works for everyone.
    private static let clusteringThreshold: Double = 0.5

    /// Directory passed to `OfflineDiarizerModels.load(from:)`. FluidAudio
    /// appends its own repo folder underneath.
    static func storageURL(forID _: String) -> URL {
        ModelStorage.diarizationRoot()
    }

    /// On-disk check. We look for the four `.mlmodelc` bundles FluidAudio's
    /// offline diarizer needs. The PLDA JSON sidecar is downloaded alongside
    /// them but lives in a path that's tried in several locations at load
    /// time, so we don't rely on a specific filename for the check — if all
    /// four CoreML packages are present, the snapshot is whole.
    static func modelsExist(id _: String) -> Bool {
        let folder = ModelStorage.diarizationRoot()
            .appendingPathComponent("speaker-diarization", isDirectory: true)
        let fm = FileManager.default
        let required = [
            ModelNames.OfflineDiarizer.segmentationFile,
            ModelNames.OfflineDiarizer.fbankFile,
            ModelNames.OfflineDiarizer.embeddingFile,
            ModelNames.OfflineDiarizer.pldaRhoFile,
        ]
        return required.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Download the model bundle (no in-memory load) and report fractional
    /// progress. Same shape as `ParakeetService.download` so `ModelManager`'s
    /// download Task wrapper can be cloned verbatim.
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let directory = Self.storageURL(forID: modelID)
        let onFraction: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(fraction) }
        }
        try await Self.runDownload(directory: directory, onFraction: onFraction)
    }

    /// Load the diarizer pipeline into memory. Downloads first if not on disk.
    /// Idempotent: a second call with the same id is a no-op.
    func ensureLoaded(modelID: String) async throws {
        if loadedModelID == modelID, manager != nil { return }
        manager = nil
        loadedModelID = nil
        currentModelID = nil
        isLoading = true
        defer { isLoading = false }

        let directory = Self.storageURL(forID: modelID)
        var config = OfflineDiarizerConfig.default
        config.clustering.threshold = Self.clusteringThreshold
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels(directory: directory, configuration: nil, forceRedownload: false)
        self.manager = mgr
        self.loadedModelID = modelID
        self.currentModelID = modelID
    }

    /// Drop the in-memory pipeline. Called before deleting model files from
    /// disk so we don't tear them out from under a live processor.
    func unload(modelID: String) {
        guard loadedModelID == modelID else { return }
        manager = nil
        loadedModelID = nil
        currentModelID = nil
    }

    /// Run diarization on an audio file. Returns the speaker timeline as a
    /// flat array of segments. The framework handles resampling internally,
    /// so any sample rate/channel layout `AVAudioFile` can read is acceptable.
    func diarize(audioFileAt url: URL, modelID: String) async throws -> [DiarizationSegment] {
        try await ensureLoaded(modelID: modelID)
        guard let manager else {
            throw NSError(domain: "Dictator", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Diarizer not loaded"])
        }
        let result = try await manager.process(url)
        let segments = result.segments.map {
            DiarizationSegment(
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                speakerLabel: $0.speakerId
            )
        }
        // Diagnostic: log how many speakers the clusterer surfaced. When
        // users report "I had three people on the call but it's all one
        // speaker", this is the first line to check — if `unique=1` then
        // clustering collapsed the embeddings (probably codec/SNR), and
        // we know to bring the threshold down rather than look elsewhere.
        let labelTotals = Dictionary(grouping: segments, by: { $0.speakerLabel })
            .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            .map { (label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
        let breakdown = labelTotals
            .map { "\($0.label)=\(String(format: "%.1f", $0.seconds))s" }
            .joined(separator: ", ")
        NSLog("[Dictator] Diarizer: segments=\(segments.count) unique=\(labelTotals.count) breakdown=[\(breakdown)] (threshold=\(Self.clusteringThreshold))")
        return segments
    }

    // MARK: - Nonisolated bridge

    private nonisolated static func runDownload(
        directory: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        // We call OfflineDiarizerModels.load directly (rather than
        // OfflineDiarizerManager.prepareModels) because only the former
        // exposes a progress handler. The result is discarded — we just
        // wanted the bytes on disk; the actual load into RAM happens on
        // first use via ensureLoaded.
        _ = try await OfflineDiarizerModels.load(
            from: directory,
            configuration: nil,
            progressHandler: { progress in
                onFraction(progress.fractionCompleted)
            }
        )
    }
}

/// One contiguous span attributed to a single speaker by the diarizer.
/// `speakerLabel` is FluidAudio's cluster id (e.g. "Speaker 1") — stable
/// within a single diarization run, opaque otherwise.
struct DiarizationSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String
}
