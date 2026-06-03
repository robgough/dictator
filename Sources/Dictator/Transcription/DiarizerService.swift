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

    /// Clustering threshold passed to FluidAudio's `OfflineDiarizerConfig`.
    ///
    /// IMPORTANT — direction of this knob (it is NOT "distance" despite the
    /// field name elsewhere). FluidAudio treats this value as a cosine-style
    /// *similarity* and converts it to an AHC dendrogram cut distance via
    /// `sqrt(2 - 2·threshold)`. So a HIGHER threshold → a SMALLER cut distance
    /// → MORE clusters (speakers kept apart); a LOWER threshold → a LARGER cut
    /// distance → MORE merging (distinct voices collapsed into one). The old
    /// value here (0.5) and its comment had this exactly backwards: 0.5
    /// produces the *largest* cut distance of any sane value and so the most
    /// aggressive merging.
    ///
    /// Measured on real meeting audio (scratch/diar-eval threshold sweep,
    /// 6-minute system-track slices):
    ///   - A two-person interview that collapsed to a single speaker in
    ///     production stayed merged (unique=1) at 0.40–0.55 and split correctly
    ///     into two voices (unique=2) at 0.60–0.80.
    ///   - Two already-correct multi-speaker clips were unchanged across the
    ///     whole 0.50–0.80 range — i.e. raising the threshold fixed the
    ///     collapse with no over-segmentation cost.
    /// 0.60–0.80 is a flat plateau on that data; 0.65 sits inside it with a
    /// margin above the 0.55→0.60 transition so codec variation that nudges
    /// embeddings slightly doesn't drop a call back into the collapsed regime.
    /// Exposed as a constant rather than a setting until we see whether one
    /// threshold works for everyone.
    private static let clusteringThreshold: Double = 0.65

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
        // Keep overlapping segments. The pyannote community-1 segmentation
        // model emits per-frame activity for up to 3 simultaneous speakers;
        // FluidAudio's default `exclusiveSegments = true` trims later segments
        // so only one speaker is active per moment, throwing away the overlap
        // signal entirely. Downstream `MeetingProcessor.attributeSpeakers`
        // resolves which speaker owns each *word* in an overlap region.
        config.postProcessing.exclusiveSegments = false
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
    /// flat array of segments plus the per-cluster centroid embeddings used
    /// by the multi-track merger to identify the same person across the mic
    /// and system recordings. The framework handles resampling internally,
    /// so any sample rate/channel layout `AVAudioFile` can read is acceptable.
    ///
    /// `trackLabel` is purely for the diagnostic NSLog — pass "mic", "system",
    /// or whatever name the caller uses for the track. It has no effect on
    /// the diarization result itself.
    ///
    /// `exclusiveSegments` is disabled in the config we pass to FluidAudio,
    /// so the segments here can (and often do) overlap in time. The pyannote
    /// community-1 segmentation model emits per-frame activity for up to 3
    /// simultaneous speakers; suppressing overlap was throwing that signal
    /// away. `MeetingProcessor.attributeSpeakers` handles the overlap-aware
    /// word attribution downstream.
    func diarize(audioFileAt url: URL, modelID: String, trackLabel: String) async throws -> DiarizationOutput {
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
        // `speakerDatabase` is the per-cluster mean embedding FluidAudio
        // accumulates while building the reconstruction. nil only when the
        // pipeline didn't run clustering (e.g. empty audio); we treat that
        // as an empty dict so the merger can still match by co-occurrence.
        let centroids = result.speakerDatabase ?? [:]
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
        NSLog("[Dictator] Diarizer[\(trackLabel)]: segments=\(segments.count) unique=\(labelTotals.count) breakdown=[\(breakdown)] (threshold=\(Self.clusteringThreshold))")
        return DiarizationOutput(segments: segments, clusterCentroids: centroids)
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
/// within a single diarization run, opaque otherwise (different tracks
/// produce different cluster IDs for the same physical person).
struct DiarizationSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String
}

/// One diarizer run's full output. `clusterCentroids` maps each cluster
/// label (matching `DiarizationSegment.speakerLabel`) to the per-speaker
/// mean embedding FluidAudio accumulated while building the reconstruction.
/// `MeetingProcessor` compares centroids across the mic and system runs to
/// recognise when "S1 on mic" and "S2 on system" are the same person
/// bleeding across both tracks.
struct DiarizationOutput: Sendable {
    let segments: [DiarizationSegment]
    let clusterCentroids: [String: [Float]]
}
