import Foundation
@preconcurrency import AVFoundation

/// Shrinks finished meetings on disk. Live recordings are written as
/// crash-safe LinearPCM CAF (Int16 mono, ~350 MB/hour/track at 48 kHz —
/// see `MeetingStorage`'s header for why PCM CAF during capture); once the
/// post-pass has produced a transcript that crash-safety rationale expires,
/// so each PCM track is re-encoded in place to mono AAC inside the same
/// `.caf` filename — the exact shape `MeetingImporter` already writes for
/// imports, ~10× smaller, and transparently readable by everything that
/// touches the file (`AVAudioFile` for re-processing, `AVAudioPlayer` for
/// playback). Keeping the filename means no meta migration: `audioFiles`
/// in `meta.json` stays a presence flag and every URL helper keeps working.
///
/// Two entry points:
///   - `compact(meetingID:)` — fired by `MeetingSession.runProcessor`
///     right after a successful post-pass.
///   - `sweepOnce()` — once per launch from `MeetingsStore.refresh()`,
///     walks the back catalog so meetings recorded before compaction
///     existed (or whose compaction was interrupted by a quit) get shrunk
///     too. Meetings whose post-pass is currently running are skipped —
///     the session compacts them itself when it finishes.
///
/// Failure is always safe: the AAC is written to a sibling temp file,
/// verified for duration, and atomically swapped in — any error leaves the
/// PCM original untouched for the next sweep to retry. Deleting the old
/// file out from under an active `AVAudioPlayer`/`AVAudioFile` is fine
/// (the open descriptor keeps the unlinked inode alive); the next load
/// picks up the AAC copy.
@MainActor
final class MeetingAudioCompactor {
    static let shared = MeetingAudioCompactor()

    /// Meetings whose post-pass is currently running. The launch sweep
    /// skips them; `MeetingSession.runProcessor` compacts on completion.
    private var processing: Set<UUID> = []
    /// Meetings with a compaction in flight, so the post-pass hook and the
    /// launch sweep can't transcode the same track twice concurrently.
    private var inFlight: Set<UUID> = []
    private var didSweep = false

    private init() {}

    func markProcessing(id: UUID) { processing.insert(id) }
    func unmarkProcessing(id: UUID) { processing.remove(id) }

    /// Compact the back catalog, once per launch. Subsequent calls (the
    /// store refreshes on every Meetings-window appear) are no-ops; fresh
    /// meetings are handled by the `runProcessor` hook instead.
    func sweepOnce() {
        guard !didSweep else { return }
        didSweep = true
        Task { [weak self] in
            for meta in MeetingsStore.shared.metas {
                guard let self, !self.processing.contains(meta.id) else { continue }
                await self.compact(meetingID: meta.id)
            }
        }
    }

    /// Re-encode any PCM track of one meeting to AAC, sequentially (one
    /// encoder at a time keeps the background CPU draw flat). Tracks that
    /// are already AAC — imports, previously-compacted meetings — are
    /// detected from the file header and skipped, so this is idempotent.
    func compact(meetingID: UUID) async {
        guard !inFlight.contains(meetingID) else { return }
        inFlight.insert(meetingID)
        defer { inFlight.remove(meetingID) }
        // Build the folder path by hand: `MeetingStorage.audioFolder(for:)`
        // creates the directory on access, which would resurrect a meeting
        // the user deleted while a sweep was pending.
        let folder = MeetingStorage.audioRoot()
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
        for filename in [MeetingStorage.micFilename, MeetingStorage.systemFilename] {
            await Self.compactTrack(at: folder.appendingPathComponent(filename))
        }
    }

    /// One track: header-check → AAC temp → verify → atomic swap. Runs on
    /// the global executor; the heavy decode/encode loop is
    /// `MeetingImporter.reencodeAudio` at `.utility` priority.
    private nonisolated static func compactTrack(at url: URL) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        // Header probe, scoped so the file is closed again before the swap.
        // Only LinearPCM needs compacting; anything else is already AAC.
        let probe: (isPCM: Bool, duration: Double)? = {
            guard let f = try? AVAudioFile(forReading: url) else { return nil }
            let desc = f.fileFormat.streamDescription.pointee
            return (desc.mFormatID == kAudioFormatLinearPCM,
                    Double(f.length) / f.fileFormat.sampleRate)
        }()
        guard let probe, probe.isPCM else { return }

        // "mic.caf" → "mic.compacting.caf" — the extension must stay `caf`
        // so AVAudioFile infers the container. Nothing else ever looks for
        // this name, and `reencodeAudio` clears a stale one from a crash.
        let base = url.deletingPathExtension().lastPathComponent
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("\(base).compacting.caf")
        let originalBytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        do {
            try await MeetingImporter.reencodeAudio(from: url, to: tmp, priority: .utility) { _ in }
            // Trust-but-verify before deleting the original: the AAC copy
            // must decode to (within priming-delay tolerance) the same
            // duration. A mismatch means a truncated/failed encode.
            guard let out = try? AVAudioFile(forReading: tmp) else {
                throw NSError(domain: "Dictator.Meetings", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "Compacted file is unreadable."])
            }
            let outDuration = Double(out.length) / out.fileFormat.sampleRate
            guard abs(outDuration - probe.duration) <= max(0.5, probe.duration * 0.01) else {
                throw NSError(domain: "Dictator.Meetings", code: -7,
                              userInfo: [NSLocalizedDescriptionKey: "Compacted duration \(outDuration)s != source \(probe.duration)s."])
            }
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            let newBytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            NSLog("[Dictator] Compacted \(url.lastPathComponent): %.1f MB → %.1f MB",
                  Double(originalBytes) / 1_048_576, Double(newBytes) / 1_048_576)
        } catch {
            // Keep the PCM original — bigger but intact, retried next sweep.
            try? fm.removeItem(at: tmp)
            NSLog("[Dictator] Compaction failed for \(url.lastPathComponent), keeping PCM: \(error)")
        }
    }
}
