import Foundation
@preconcurrency import AVFoundation
@preconcurrency import FluidAudio

/// Wraps FluidAudio's `SlidingWindowAsrManager` so the dictation pipeline
/// can produce live interim transcripts while the user holds the hotkey.
///
/// One instance per recording. The streamer reuses `AsrModels` loaded by
/// `ParakeetService` so we don't pay the (~600 MB) weight load twice — the
/// per-recording allocations are only the streaming manager and its internal
/// `AsrManager` decoder copy.
///
/// We deliberately use a much smaller chunk than `SlidingWindowAsrConfig.streaming`
/// (which is tuned for meetings — 11s chunk + 2s right context means no
/// interim text would appear until ~13s into a recording, longer than most
/// dictations). The trade-off is that short chunks degrade transcript quality,
/// so the canonical final transcript still goes through the offline
/// `ParakeetService.transcribe` on the full audio buffer. This service exists
/// purely for visible HUD feedback during the hold.
@MainActor
final class ParakeetStreamingService {
    /// Streaming config tuned for short, hotkey-driven dictations. First
    /// update lands at `chunkSeconds + rightContextSeconds` after the user
    /// starts speaking; subsequent updates land every `chunkSeconds`. The
    /// encoder receives a window of `left + chunk + right` audio on each
    /// step, so total context per pass is ~1.5 s — enough for Parakeet to
    /// produce sensible tokens, but short enough to update sub-second.
    /// We pay a CoreML encoder pass per chunk, so don't push these any
    /// smaller without measuring on the slowest target Mac.
    static let dictationConfig = SlidingWindowAsrConfig(
        chunkSeconds: 0.5,
        hypothesisChunkSeconds: 0.5, // declared but unused inside FluidAudio
        leftContextSeconds: 0.75,
        rightContextSeconds: 0.25,
        minContextForConfirmation: 0.3,
        confirmationThreshold: 0.5
    )

    private var streamer: SlidingWindowAsrManager?
    private var nativeSampleRate: Double = 0
    private var inputFormat: AVAudioFormat?

    /// True between a successful `start()` and a `finish()` or `cancel()`.
    /// Pipeline reads this to decide whether to trust the streaming-final
    /// path or fall back to the offline transcribe.
    private(set) var isReady: Bool = false

    /// Latest two-tier text (`confirmedTranscript` + space + `volatileTranscript`).
    /// Drained by Pipeline on each yield and pushed into `PipelineState.recording`.
    private(set) var interimStream: AsyncStream<String>!
    private var interimContinuation: AsyncStream<String>.Continuation!

    private var updatesTask: Task<Void, Never>?

    init() {
        let (stream, cont) = AsyncStream<String>.makeStream()
        self.interimStream = stream
        self.interimContinuation = cont
    }

    /// Start the streaming manager using already-loaded Parakeet weights. The
    /// returned task is the one feeding `interimStream` — it auto-cancels when
    /// the streamer's `transcriptionUpdates` continuation finishes (after
    /// `finish()` or `cancel()`).
    func start(models: AsrModels) async throws {
        let mgr = SlidingWindowAsrManager(config: Self.dictationConfig)
        try await mgr.loadModels(models)
        try await mgr.startStreaming(source: .microphone)
        self.streamer = mgr
        self.isReady = true

        let updates = await mgr.transcriptionUpdates
        let cont = interimContinuation!
        updatesTask = Task.detached { [weak mgr] in
            for await _ in updates {
                guard let mgr else { return }
                let confirmed = await mgr.confirmedTranscript
                let volatile = await mgr.volatileTranscript
                let merged: String
                if confirmed.isEmpty {
                    merged = volatile
                } else if volatile.isEmpty {
                    merged = confirmed
                } else {
                    merged = confirmed + " " + volatile
                }
                cont.yield(merged)
            }
        }
    }

    /// Push native-rate mono samples into the streamer. FluidAudio resamples
    /// to 16 kHz internally; we just have to hand it an `AVAudioPCMBuffer`
    /// with a format that matches the samples we're passing.
    func feed(samples: [Float], sampleRate: Double) {
        guard let streamer else { return }
        guard !samples.isEmpty, sampleRate > 0 else { return }

        if inputFormat == nil || abs(nativeSampleRate - sampleRate) > 1 {
            nativeSampleRate = sampleRate
            inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        }
        guard let format = inputFormat,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src -> Void in
                memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
            }
        }

        Task { [streamer, buffer] in
            await streamer.streamAudio(buffer)
        }
    }

    /// Finish streaming and return the final transcript. Idempotent-ish: a
    /// second call returns the empty string because `finish()` on the actor
    /// has already drained the input stream.
    func finish() async throws -> String {
        guard let streamer else { return "" }
        let text = try await streamer.finish()
        interimContinuation.finish()
        updatesTask?.cancel()
        updatesTask = nil
        await streamer.cleanup()
        self.streamer = nil
        self.isReady = false
        return text
    }

    /// Abandon the in-flight stream without waiting for a final transcript.
    func cancel() {
        let snapshot = streamer
        streamer = nil
        isReady = false
        interimContinuation.finish()
        updatesTask?.cancel()
        updatesTask = nil
        Task { await snapshot?.cancel() }
    }
}
