import Foundation
@preconcurrency import CoreML
@preconcurrency import FluidAudio

/// Speaker diarization for the meetings pipeline. Mirrors `ParakeetService`
/// in shape (download / ensureLoaded / unload / one operation method) so the
/// Models pane can render its rows without a special case.
///
/// Two engines, selected by catalogue id:
///
/// - **pyannote community-1** (`OfflineDiarizerManager`): segmentation +
///   WeSpeaker embeddings, clustered. Its per-cluster mean embedding is the
///   voiceprint `MeetingProcessor` and `PeopleStore` work with.
/// - **Nemotron 3 Diarization** (`Nemotron3Diarizer`): end-to-end — it emits
///   per-frame activity for up to 8 arrival-ordered speakers, with no
///   clustering and **no embeddings**. It's more accurate (it separated six
///   voices in a crowded clip pyannote had as two) but three things downstream
///   need a voiceprint per speaker: the bleed-cluster backstop, over-split
///   repair and people recognition. So in Nemotron mode pyannote *also* runs,
///   only for its timed chunk embeddings, and each Nemotron speaker gets the
///   mean of the chunks it clearly owns (`nemotronCentroids`). Those are
///   WeSpeaker vectors — the same space as pyannote's centroids (measured
///   0.92–1.00 cosine against pyannote's own centroid for the same person), so
///   stored voiceprints keep matching across a switch; see
///   `ModelCatalog.voiceprintSpaceID`. Timing alone can't stand in for them:
///   on a listen-only call the system track talks ~98% of the time, so "sits
///   inside system speech" would also be true of the user's own voice.
///
/// Storage layout. `OfflineDiarizerModels.load(from:)` treats the supplied
/// URL as the parent directory and appends `Repo.diarizer.folderName`
/// ("speaker-diarization") itself; Nemotron's bundle lands beside it in
/// `Repo.nemotron3Diarization.folderName`. Both under
/// `~/Library/Application Support/Dictator/Models/diarization/`.
@MainActor
@Observable
final class DiarizerService {
    /// ID of the model currently held in memory (nil when nothing loaded).
    private(set) var currentModelID: String?
    /// True while `ensureLoaded` or `download` is running. Drives spinners.
    private(set) var isLoading: Bool = false

    /// pyannote. Loaded for both engines — in Nemotron mode it supplies the
    /// embeddings only.
    @ObservationIgnored private var manager: OfflineDiarizerManager?
    @ObservationIgnored private var nemotron: NemotronRunner?
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

    /// Nemotron preset. `offline` (27 s chunks, 30 s latency — irrelevant for
    /// a post-pass) is the most accurate of the lineup. It only compiles for
    /// the GPU, so it's pinned to `.cpuAndGPU`: with `.all` CoreML first tries
    /// the Neural Engine, and the ANE route measured a 76 s first load against
    /// 0.3 s. An hour of audio then takes ~2.2 s (scratch/nemotron-eval).
    nonisolated static let nemotronConfig = Nemotron3Config.offline
    private static let nemotronComputeUnits: MLComputeUnits = .cpuAndGPU

    static func isNemotron(_ id: String) -> Bool { id == ModelCatalog.nemotronDiarizationID }

    /// Directory passed to `OfflineDiarizerModels.load(from:)` and to
    /// `Nemotron3Models.loadFromHuggingFace(cacheDirectory:)`. FluidAudio
    /// appends its own repo folder underneath for both.
    static func storageURL(forID _: String) -> URL {
        ModelStorage.diarizationRoot()
    }

    static var pyannoteDirectory: URL {
        ModelStorage.diarizationRoot().appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    static var nemotronDirectory: URL {
        ModelStorage.diarizationRoot().appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }

    /// On-disk check. For pyannote we look for the four `.mlmodelc` bundles
    /// FluidAudio's offline diarizer needs. The PLDA JSON sidecar is downloaded
    /// alongside them but lives in a path that's tried in several locations at
    /// load time, so we don't rely on a specific filename for the check — if
    /// all four CoreML packages are present, the snapshot is whole.
    ///
    /// Nemotron needs those too (it borrows pyannote's embeddings), plus its
    /// preset bundle, the silence embedding, and FluidAudio's weights-version
    /// marker — without the marker `loadFromHuggingFace` treats the cache as a
    /// superseded checkpoint and deletes it, so "files present" alone would
    /// report ready and then re-download on first use.
    static func modelsExist(id: String) -> Bool {
        let fm = FileManager.default
        let pyannote = [
            ModelNames.OfflineDiarizer.segmentationFile,
            ModelNames.OfflineDiarizer.fbankFile,
            ModelNames.OfflineDiarizer.embeddingFile,
            ModelNames.OfflineDiarizer.pldaRhoFile,
        ].allSatisfy { fm.fileExists(atPath: pyannoteDirectory.appendingPathComponent($0).path) }
        guard pyannote else { return false }
        guard isNemotron(id) else { return true }

        let dir = nemotronDirectory
        let bundle = dir
            .appendingPathComponent(nemotronConfig.hubSubdirectory)
            .appendingPathComponent(nemotronConfig.modelFileName)
            .appendingPathComponent("coremldata.bin")
        let marker = dir.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        let markerCurrent = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == ModelNames.Nemotron3.weightsVersion
        return markerCurrent
            && fm.fileExists(atPath: bundle.path)
            && fm.fileExists(atPath: dir.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile).path)
    }

    /// Download the model bundle(s) (no in-memory load) and report fractional
    /// progress. Same shape as `ParakeetService.download` so `ModelManager`'s
    /// download Task wrapper can be cloned verbatim. Nemotron fetches
    /// pyannote's bundle first (21 MB, the first tenth of the bar), then its
    /// own (200 MB).
    func download(modelID: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        let directory = Self.storageURL(forID: modelID)
        let nemotron = Self.isNemotron(modelID)
        let pyannoteShare = nemotron ? 0.1 : 1.0
        // The per-callback Task hops don't arrive in order, so a late pyannote
        // callback can land after Nemotron's first; never let the bar go back.
        var shown = 0.0
        let progress: @MainActor (Double) -> Void = { fraction in
            guard fraction >= shown else { return }
            shown = fraction
            progress(fraction)
        }
        let onPyannote: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(fraction * pyannoteShare) }
        }
        try await Self.runDownload(directory: directory, onFraction: onPyannote)
        guard nemotron else { return }
        let onNemotron: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in progress(pyannoteShare + fraction * (1 - pyannoteShare)) }
        }
        try await Self.runNemotronDownload(directory: directory, onFraction: onNemotron)
    }

    /// Load the diarizer pipeline into memory. Downloads first if not on disk.
    /// Idempotent: a second call with the same id is a no-op.
    func ensureLoaded(modelID: String) async throws {
        if loadedModelID == modelID, manager != nil { return }
        manager = nil
        nemotron = nil
        loadedModelID = nil
        currentModelID = nil
        isLoading = true
        defer { isLoading = false }

        let directory = Self.storageURL(forID: modelID)
        let useNemotron = Self.isNemotron(modelID)
        var config = OfflineDiarizerConfig.default
        config.clustering.threshold = Self.clusteringThreshold
        // Keep overlapping segments. The pyannote community-1 segmentation
        // model emits per-frame activity for up to 3 simultaneous speakers;
        // FluidAudio's default `exclusiveSegments = true` trims later segments
        // so only one speaker is active per moment, throwing away the overlap
        // signal entirely. Downstream `MeetingProcessor.attributeSpeakers`
        // resolves which speaker owns each *word* in an overlap region.
        config.postProcessing.exclusiveSegments = false
        // Nemotron mode reads pyannote's per-chunk embeddings, which FluidAudio
        // only keeps when asked (~1–2 MB per hour of audio).
        config.exposeChunkEmbeddings = useNemotron
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels(directory: directory, configuration: nil, forceRedownload: false)

        if useNemotron {
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: Self.nemotronConfig,
                cacheDirectory: directory,
                computeUnits: Self.nemotronComputeUnits
            )
            self.nemotron = NemotronRunner(
                diarizer: Nemotron3Diarizer(config: Self.nemotronConfig, models: models))
        }
        self.manager = mgr
        self.loadedModelID = modelID
        self.currentModelID = modelID
    }

    /// Drop the in-memory pipeline. Called before deleting model files from
    /// disk so we don't tear them out from under a live processor.
    func unload(modelID: String) {
        guard loadedModelID == modelID else { return }
        unloadAll()
    }

    /// Drop whatever is loaded. The meetings post-pass calls this when it's
    /// done, without caring which engine the user had picked.
    func unloadAll() {
        manager = nil
        nemotron = nil
        loadedModelID = nil
        currentModelID = nil
    }

    /// Diarize already-decoded 16 kHz mono samples. Returns the speaker
    /// timeline as a flat array of segments plus the per-speaker centroid
    /// embeddings used by the multi-track merger to identify the same person
    /// across the mic and system recordings.
    ///
    /// `trackLabel` is purely for the diagnostic NSLog — pass "mic", "system",
    /// or whatever name the caller uses for the track. It has no effect on
    /// the diarization result itself.
    ///
    /// Segments can (and often do) overlap in time, from either engine: pyannote
    /// with `exclusiveSegments` disabled (see `ensureLoaded`), Nemotron by
    /// construction — it scores all 8 speakers independently per frame.
    /// `MeetingProcessor.attributeSpeakers` handles the overlap-aware word
    /// attribution downstream.
    func diarize(samples: [Float], modelID: String, trackLabel: String) async throws -> DiarizationOutput {
        try await ensureLoaded(modelID: modelID)
        guard let manager else {
            throw NSError(domain: "Dictator", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "Diarizer not loaded"])
        }
        guard let nemotron else {
            return Self.makeOutput(try await manager.process(audio: samples), trackLabel: trackLabel)
        }

        let started = Date()
        let segments = try await Task.detached(priority: .userInitiated) {
            try nemotron.segments(samples)
        }.value
        let nemotronSeconds = Date().timeIntervalSince(started)

        // Voiceprints from pyannote's chunk embeddings. A failure here costs
        // the bleed backstop, over-split repair and people recognition for
        // this track, not the diarization — the segments are already good.
        var centroids: [String: [Float]] = [:]
        do {
            let embeddingPass = try await manager.process(audio: samples)
            centroids = Self.nemotronCentroids(segments: segments, chunks: embeddingPass.chunkEmbeddings ?? [])
        } catch {
            NSLog("[Dictator] Diarizer[\(trackLabel)]: Nemotron voiceprint pass failed, continuing without: \(error)")
        }
        let output = DiarizationOutput(segments: segments, clusterCentroids: centroids)
        Self.log(output, trackLabel: trackLabel,
                 detail: "engine=nemotron \(String(format: "%.1fs", nemotronSeconds)) voiceprints=\(centroids.count)")
        return output
    }

    /// Give each Nemotron speaker a voiceprint: the mean of the unit-normalised
    /// pyannote chunk embeddings whose span that speaker clearly owns.
    ///
    /// A chunk embedding covers one pyannote-local speaker's activity within a
    /// ~10 s window (median span measured at 8.5–10 s), so it can straddle a
    /// turn change. It's only used when one Nemotron speaker covers ≥60% of its
    /// span AND at least 3× the runner-up — a mixed chunk would drag the
    /// centroid toward both people, which is how two voices end up matching.
    /// On the test clips 55–98% of chunks qualify, and every speaker with more
    /// than a couple of seconds of speech gets one. A speaker that gets none
    /// simply has no centroid, which every consumer already handles.
    nonisolated static func nemotronCentroids(
        segments: [DiarizationSegment],
        chunks: [ChunkEmbedding]
    ) -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        for chunk in chunks {
            let span = chunk.endTimeSeconds - chunk.startTimeSeconds
            guard span > 0 else { continue }
            var cover: [String: Double] = [:]
            for seg in segments {
                let overlap = min(seg.end, chunk.endTimeSeconds) - max(seg.start, chunk.startTimeSeconds)
                if overlap > 0 { cover[seg.speakerLabel, default: 0] += overlap }
            }
            let ranked = cover.sorted { $0.value > $1.value }
            guard let top = ranked.first, top.value / span >= 0.6,
                  ranked.count < 2 || ranked[1].value * 3 <= top.value else { continue }
            let norm = chunk.embedding256.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { continue }
            var sum = sums[top.key] ?? [Float](repeating: 0, count: chunk.embedding256.count)
            guard sum.count == chunk.embedding256.count else { continue }
            for i in sum.indices { sum[i] += chunk.embedding256[i] / norm }
            sums[top.key] = sum
        }
        return sums.mapValues { sum in
            let norm = sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? sum.map { $0 / norm } : sum
        }
    }

    /// Map FluidAudio's result into our flat segment/centroid shape and log the
    /// per-cluster breakdown.
    private static func makeOutput(_ result: DiarizationResult, trackLabel: String) -> DiarizationOutput {
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
        let output = DiarizationOutput(segments: segments, clusterCentroids: result.speakerDatabase ?? [:])
        log(output, trackLabel: trackLabel, detail: "engine=pyannote threshold=\(clusteringThreshold)")
        return output
    }

    /// Diagnostic: log how many speakers the diarizer surfaced. When users
    /// report "I had three people on the call but it's all one speaker", this
    /// is the first line to check — for pyannote, `unique=1` means clustering
    /// collapsed the embeddings (probably codec/SNR), and we know to bring the
    /// threshold up rather than look elsewhere.
    private static func log(_ output: DiarizationOutput, trackLabel: String, detail: String) {
        let labelTotals = Dictionary(grouping: output.segments, by: { $0.speakerLabel })
            .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            .map { (label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
        let breakdown = labelTotals
            .map { "\($0.label)=\(String(format: "%.1f", $0.seconds))s" }
            .joined(separator: ", ")
        NSLog("[Dictator] Diarizer[\(trackLabel)]: segments=\(output.segments.count) unique=\(labelTotals.count) breakdown=[\(breakdown)] (\(detail))")
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

    /// `loadFromHuggingFace` is FluidAudio's only Nemotron download path, and
    /// it also loads. The load is discarded — like `runDownload`, this is for
    /// the bytes (and the weights-version marker `modelsExist` checks).
    private nonisolated static func runNemotronDownload(
        directory: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        _ = try await Nemotron3Models.loadFromHuggingFace(
            config: nemotronConfig,
            cacheDirectory: directory,
            computeUnits: .cpuAndGPU,
            progressHandler: { progress in
                onFraction(progress.fractionCompleted)
            }
        )
    }
}

/// Owns a `Nemotron3Diarizer` so it can run off the main actor.
/// `processComplete` is synchronous and runs the whole track (seconds of GPU
/// work per hour), so it must not run on the main thread; the diarizer is a
/// non-Sendable class that FluidAudio documents as not thread-safe, so every
/// use goes through the lock.
private final class NemotronRunner: @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer
    private let lock = NSLock()

    init(diarizer: Nemotron3Diarizer) {
        self.diarizer = diarizer
    }

    /// Arrival-ordered speaker segments at 10 ms resolution. Labels follow
    /// pyannote's "S<n>" shape; like pyannote's they're opaque and per-run.
    func segments(_ samples: [Float]) throws -> [DiarizationSegment] {
        try lock.withLock {
            let (probabilities, frameCount) = try diarizer.processComplete(samples)
            return Nemotron3Diarizer.segments(probabilities: probabilities, frameCount: frameCount)
                .map {
                    DiarizationSegment(
                        start: TimeInterval($0.startSeconds),
                        end: TimeInterval($0.endSeconds),
                        speakerLabel: "S\($0.speakerIndex + 1)"
                    )
                }
        }
    }
}

/// One contiguous span attributed to a single speaker by the diarizer.
/// `speakerLabel` is the diarizer's speaker id (e.g. "S1") — stable
/// within a single diarization run, opaque otherwise (different tracks
/// produce different cluster IDs for the same physical person).
struct DiarizationSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String
}

/// One diarizer run's full output. `clusterCentroids` maps each cluster
/// label (matching `DiarizationSegment.speakerLabel`) to the per-speaker
/// mean embedding — pyannote's own, or for Nemotron the ones
/// `DiarizerService.nemotronCentroids` derives. A label can be missing from
/// it (a Nemotron speaker with no clean chunk), never the other way round.
/// `MeetingProcessor` compares centroids across the mic and system runs to
/// recognise when "S1 on mic" and "S2 on system" are the same person
/// bleeding across both tracks.
struct DiarizationOutput: Sendable {
    let segments: [DiarizationSegment]
    let clusterCentroids: [String: [Float]]
}
