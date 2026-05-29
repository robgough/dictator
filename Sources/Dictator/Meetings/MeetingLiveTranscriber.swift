import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Observation

/// Drives a live, draft transcript while a meeting is being recorded. Sits
/// alongside the two recorders (system-audio process tap + mic
/// AVCaptureSession) and consumes their buffers as they arrive, runs them
/// through Parakeet in
/// chunks larger than dictation uses, and exposes a continuously-growing
/// `interimText` the Meetings detail view reads.
///
/// The canonical, diarized transcript is still produced by `MeetingProcessor`
/// after the user stops the recording — this is purely a "watch the meeting
/// take shape" affordance. Errors here are non-fatal: a failed chunk gets
/// logged + dropped, the recording keeps running, and the post-pass
/// transcript is unaffected.
///
/// **Track strategy (v1):** mic-only. The system-audio feed is accepted (so
/// the wiring is in place for a future upgrade), but the v1 transcriber only
/// runs ASR on the mic chunks. Two parallel Parakeet runs would either
/// fight for the ANE or require a second model load — and the live UI has
/// no speaker attribution anyway, so the value of also streaming the system
/// track is bounded. The post-pass diarizer still produces both sides of
/// the conversation in the final transcript.
///
/// **Chunking:** non-overlapping 8-second windows. Each window runs through
/// the same `ParakeetServiceHolder.shared.transcribe(samples:modelID:)` call
/// the dictation flow uses — no new public API on `ParakeetService`, no
/// separate model load. The shared service is the same one the post-capture
/// processor will reach for moments later, so the model stays warm across
/// the boundary instead of being thrashed. Non-overlapping windows mean a
/// word that straddles the boundary may get cut — we accept that for the
/// draft view; the post-pass transcript is the authoritative one. The
/// alternative (overlap with dedup) is brittle for too little gain.
@MainActor
@Observable
final class MeetingLiveTranscriber {
    /// The growing draft transcript. Each completed chunk appends to this.
    /// Observable so the SwiftUI pane re-renders as new text lands.
    private(set) var interimText: String = ""

    /// True while at least one chunk has been kicked off and the transcriber
    /// hasn't been stopped. Observed by the UI to decide whether to show the
    /// "Listening…" placeholder vs. the running transcript text.
    private(set) var isRunning: Bool = false

    private let parakeetModelID: String

    /// 16 kHz mono samples not yet flushed into a chunk. Mic only — the
    /// system buffers are accepted by `feedSystemBuffer` but dropped in v1.
    @ObservationIgnored private var micBuffer: [Float] = []

    /// Task running the current chunk transcribe, if any. Cancelled on
    /// `stop()` so the in-flight inference doesn't outlive the meeting.
    @ObservationIgnored private var inflightTask: Task<Void, Never>?

    /// True iff we've started transcribing at least one chunk. Lets `stop()`
    /// distinguish "user never had a hot mic" from "we're between chunks".
    @ObservationIgnored private var hasStarted: Bool = false

    /// Target chunk size (samples at 16 kHz). 8 s × 16 kHz = 128 000.
    private static let chunkSamples: Int = 8 * 16_000

    /// Don't bother running ASR on anything shorter than this; FluidAudio's
    /// AsrManager hard-rejects sub-0.3 s inputs as `.invalidAudioData`. We
    /// pad the floor up to 0.4 s to stay clear of that edge.
    private static let minChunkSamples: Int = Int(0.4 * 16_000)

    /// `modelID` is captured here so the transcriber never reaches into
    /// settings — keeps the dependency explicit and matches the way the
    /// processor is given the model id by the session.
    init(parakeetModelID: String) {
        self.parakeetModelID = parakeetModelID
        self.isRunning = true
    }

    /// Receive mono Float32 mic audio (at the device's native rate) from
    /// `MeetingMicRecorder`. Called from the off-main capture queue — we
    /// resample to 16 kHz here, then hop to the main actor to touch the chunk
    /// state, since `[Float]` mutation and `Task` launch both belong on a
    /// single actor for this class.
    nonisolated func feedMicSamples(_ mono: [Float], sampleRate: Double) {
        guard sampleRate > 0, !mono.isEmpty else { return }
        guard let samples = AudioResampler.mono(samples: mono, from: sampleRate, to: 16_000) else { return }
        Task { @MainActor [weak self] in
            self?.appendMic(samples: samples)
        }
    }

    /// Receive a system-audio sample buffer from `MeetingAudioRecorder`.
    /// v1 ignores it (mic-only strategy) but the hook is wired so a future
    /// "live both tracks" upgrade only needs to flip a flag and add the
    /// chunk dispatch.
    nonisolated func feedSystemBuffer(_ sampleBuffer: CMSampleBuffer) {
        _ = sampleBuffer
    }

    /// Cleanly stop the live transcriber. Cancels the in-flight chunk task,
    /// drops the pending buffer, and drops the model reference so a meeting
    /// that ran for an hour doesn't keep extra state alive. The actual
    /// Parakeet weights live in `ParakeetServiceHolder.shared` and are
    /// shared with `MeetingProcessor`, which will start its post-capture
    /// pass on this same warm model microseconds after this returns — so
    /// we deliberately *don't* unload the holder here.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        inflightTask?.cancel()
        inflightTask = nil
        micBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Main-actor state

    private func appendMic(samples: [Float]) {
        guard isRunning, !samples.isEmpty else { return }
        micBuffer.append(contentsOf: samples)
        scheduleChunkIfReady()
    }

    /// If we have enough buffered audio for a chunk AND there's no chunk
    /// already in flight, slice off the front `chunkSamples` and queue it
    /// for transcription. Only one chunk at a time — the ANE can run
    /// Parakeet concurrently in principle, but stacking inferences when a
    /// long meeting falls behind real time just builds an unbounded queue.
    /// When we're behind we let the buffer grow, then flush the front 8 s
    /// as soon as the current transcribe returns; the buffered audio
    /// eventually drains. Live transcription is best-effort.
    private func scheduleChunkIfReady() {
        guard isRunning else { return }
        guard inflightTask == nil else { return }
        guard micBuffer.count >= Self.chunkSamples else { return }

        let chunk = Array(micBuffer.prefix(Self.chunkSamples))
        micBuffer.removeFirst(Self.chunkSamples)

        inflightTask = Task { @MainActor [weak self] in
            await self?.transcribe(chunk: chunk)
        }
    }

    private func transcribe(chunk: [Float]) async {
        defer {
            // Always clear inflightTask before potentially scheduling the
            // next chunk so the guard in `scheduleChunkIfReady` lets the
            // next slice through.
            inflightTask = nil
        }
        guard isRunning else { return }
        guard chunk.count >= Self.minChunkSamples else { return }
        do {
            let text = try await ParakeetServiceHolder.shared.transcribe(
                samples: chunk,
                modelID: parakeetModelID
            )
            guard isRunning, !Task.isCancelled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                scheduleChunkIfReady()
                return
            }
            if hasStarted, !interimText.isEmpty {
                interimText.append(" ")
            }
            interimText.append(trimmed)
            hasStarted = true
        } catch {
            // Live transcription failures are non-fatal — log and keep
            // recording. The post-capture transcript is the authoritative
            // one; this is just a draft.
            NSLog("[Dictator] Meeting live transcribe chunk failed: \(error)")
        }
        scheduleChunkIfReady()
    }
}
