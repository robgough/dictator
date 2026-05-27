import Foundation
@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import CoreMedia
import AppKit
import os

/// Captures **system audio** for one meeting via the CoreAudio Process Tap
/// API (`AudioHardwareCreateProcessTap`, introduced in macOS 14.4). Writes a
/// single `system.caf` file (Float32 mono) into the meeting's folder.
///
/// Why CATap instead of ScreenCaptureKit? SCK enforces Apple's
/// "screen-recording-shaped" allow list: FaceTime, Apple Music, and a
/// handful of DRM-conscious apps silently produce zero audio buffers under
/// SCK, regardless of permissions. CATap sits below that allow list and
/// captures whatever is going through the system mixer — so a Dictator
/// meeting recording finally covers FaceTime + Music + streaming services.
///
/// The mic track is still owned by `MeetingMicRecorder` (AVAudioEngine on
/// the mic input — needed for voice-processing AEC against the speakers).
/// The two recorders run in parallel; the session orchestrates lifecycle.
///
/// Shape modelled on insidegui/AudioCap (`ProcessTap.swift`), adapted to
/// keep the recorder's existing public surface (`onReady`, `onLevel`,
/// `onUnexpectedStop`, `onBuffer`, `start`/`stop`) so the session and live
/// transcriber don't shift around this rewrite.
@MainActor
final class MeetingAudioRecorder {
    /// Stable UID prefix for our private aggregate devices. The full UID is
    /// `\(aggregateUIDPrefix)\(uuid)`; the prefix is what `sweepStaleAggregates()`
    /// uses to recognise our own leaked devices and reap them on launch.
    /// Bundle ID is in there so a future re-namespacing of the app doesn't
    /// accidentally inherit some other product's leaked UIDs.
    private static let aggregateUIDPrefix = "net.robgough.Dictator.meetingTap-"

    @ObservationIgnored private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored private var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private var tapFormat: AVAudioFormat?
    @ObservationIgnored private var systemFile: AVAudioFile?
    @ObservationIgnored private var running = false

    /// Where the system audio is being written. Populated by `start`.
    private(set) var systemURL: URL?
    private(set) var startedAt: Date?

    /// Fired once the CATap IOProc has been started successfully. The
    /// session's `warmingUp` → `recording` pivot hangs off this.
    var onReady: (@MainActor () -> Void)?

    /// Fired on each successful system-audio buffer with the current
    /// system RMS level (0…1). The mic level is owned by
    /// `MeetingMicRecorder` and arrives on a separate callback. The mic
    /// argument here is retained as 0 to keep the API ergonomic for
    /// callers that snapshot both into the same state.
    var onLevel: (@MainActor (_ mic: Float, _ system: Float) -> Void)?

    /// Fired if the IOProc stops itself outside our control. Rare on CATap
    /// — mostly happens if the default output device disappears (HDMI
    /// unplug, USB DAC powered off) and the aggregate's main sub-device
    /// goes away with it.
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    /// Fired once per recording with a human-readable reason the system
    /// capture looks unhealthy. With CATap the historical "FaceTime / Apple
    /// Music is blocking us" failure mode is gone — this now mainly fires
    /// if the IOProc starts but never delivers a buffer (e.g. nothing on
    /// the system is producing audio for the full watchdog window). The
    /// session pipes this into `captureWarnings` for the LiveRecordingView
    /// banner.
    var onCaptureWarning: (@MainActor (String) -> Void)?

    /// Optional sink for raw system-audio sample buffers, fired alongside
    /// the on-disk write. The live-transcript service hangs off this so it
    /// could re-encode each buffer for Parakeet. In v1 the live transcriber
    /// drops system buffers (mic-only strategy), but we still synthesise a
    /// CMSampleBuffer here to preserve the contract — a future "live both
    /// tracks" upgrade picks it up for free. **Fires on the CATap audio
    /// queue (`Self.audioQueue`), not the main actor** — the callee owns
    /// any actor hop. Set once at `start` time and never reassigned.
    var onBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    /// Flipped on the CATap audio queue the first time a real audio buffer
    /// arrives. Read on the main actor by the bring-up watchdog 5 s after
    /// start. `OSAllocatedUnfairLock<Bool>` is the async-safe primitive:
    /// `NSLock` traps when called from an async context under Swift 6
    /// strict concurrency.
    private let firstAudioBufferFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var bringUpWatchdog: Task<Void, Never>?

    private var lastSystemLevel: Float = 0

    init() {}

    /// Build the tap + aggregate device + IOProc, open the AVAudioFile
    /// lazily on first sample, and begin capture. Throws on permission
    /// denied (tap creation fails with an OSStatus the user sees in the
    /// error string) or aggregate / IOProc setup failure.
    func start(folder: URL, preferredMicUID: String?) async throws {
        guard !running else { return }
        _ = preferredMicUID // mic capture lives in MeetingMicRecorder

        // Reap any leaked aggregate devices from a previous crashed session
        // before we add a new one. Cheap (single HAL property read).
        Self.sweepStaleAggregates()

        let systemPath = folder.appendingPathComponent(MeetingStorage.systemFilename)
        self.systemURL = systemPath
        try? FileManager.default.removeItem(at: systemPath)

        NSLog("[Dictator] MeetingSystem: starting — destination=\(systemPath.lastPathComponent)")

        // 1. Build the process tap. Stereo, global, with our own AudioObject
        // ID in the exclude list — same intent as SCK's
        // `excludesCurrentProcessAudio`, implemented at the HAL layer so we
        // never sniff our own UI sounds back through the mix. If the PID
        // can't be translated (our process hasn't appeared in the audio
        // process list yet because we haven't played any audio in this
        // session) we proceed with an empty exclude list — Dictator
        // produces no meaningful audio, so the worst case is harmless.
        let excludeIDs: [AudioObjectID]
        if let ownObject = Self.translatePIDToAudioProcessObject(pid: ProcessInfo.processInfo.processIdentifier) {
            excludeIDs = [ownObject]
        } else {
            excludeIDs = []
        }
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeIDs)
        tapDesc.name = "Dictator meeting capture"
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted // never mute the user's playback while capturing

        var tapID: AUAudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapErr == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            NSLog("[Dictator] MeetingSystem: AudioHardwareCreateProcessTap failed: \(tapErr)")
            throw NSError(
                domain: "Dictator.Meetings", code: Int(tapErr),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create the system audio tap (OSStatus \(tapErr)). Dictator needs System Audio Recording permission — open System Settings to grant it."]
            )
        }
        self.processTapID = tapID

        // 2. Read the tap's stream format so we can describe the aggregate
        // device and the in-IOProc PCM extraction without guessing.
        let streamDesc = try Self.readTapStreamDescription(tapID: tapID)
        self.tapStreamDescription = streamDesc
        var mutableStreamDesc = streamDesc
        let tapFormat = AVAudioFormat(streamDescription: &mutableStreamDesc)
        self.tapFormat = tapFormat
        NSLog("[Dictator] MeetingSystem: tap format — rate=\(streamDesc.mSampleRate) ch=\(streamDesc.mChannelsPerFrame) flags=0x\(String(streamDesc.mFormatFlags, radix: 16))")

        // 3. Build the aggregate device. We need a main sub-device for the
        // clock — the default system output is the conventional choice and
        // matches what AudioCap does. The tap is added as a sub-tap with
        // drift compensation enabled so any clock skew between the tap and
        // the output device is corrected by the HAL.
        let defaultOutputID = try Self.readDefaultSystemOutputDevice()
        let outputUID = try Self.readDeviceUID(deviceID: defaultOutputID)
        let aggregateUID = "\(Self.aggregateUIDPrefix)\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dictator Meeting Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                ]
            ],
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard aggErr == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            NSLog("[Dictator] MeetingSystem: AudioHardwareCreateAggregateDevice failed: \(aggErr)")
            // Tear down the tap we just created — no aggregate means
            // nothing to drive it, so leaving it around just leaks.
            _ = AudioHardwareDestroyProcessTap(tapID)
            self.processTapID = AudioObjectID(kAudioObjectUnknown)
            throw NSError(
                domain: "Dictator.Meetings", code: Int(aggErr),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create the aggregate device for system capture (OSStatus \(aggErr))."]
            )
        }
        self.aggregateDeviceID = aggID

        // 4. Snapshot the buffer sink + tap format into Sendable locals so
        // the IOProc block — running on the audio queue — never has to
        // hop the main actor to read them back off `self`. `self` is
        // captured weakly so the deinit path can collapse safely.
        let bufferSink = onBuffer
        let queueFormat = tapFormat
        let firstFlag = firstAudioBufferFlag

        var procID: AudioDeviceIOProcID?
        // `@Sendable` is load-bearing for the same reason MeetingMicRecorder's
        // `installTap` closure carries it: AudioDeviceCreateIOProcIDWithBlock
        // dispatches this block on `Self.audioQueue`, which is not the main
        // actor. Without the annotation, Swift 6 inherits @MainActor isolation
        // from the enclosing `start()` method, and the runtime traps with
        // `_dispatch_assert_queue_fail` the first time a real audio buffer
        // arrives (so without anything playing through the system you never
        // see the bug — silence means zero IOProc invocations).
        let createErr = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggID,
            Self.audioQueue
        ) { @Sendable [weak self] _, inInputData, _, _, _ in
            // `inInputData` is the AudioBufferList carrying the tap's PCM
            // samples for this IO cycle. Each cycle is short (the HAL
            // schedules at the device's preferred buffer size — typically
            // ~10 ms at 48 kHz), so per-call work has to stay cheap.
            //
            // Order matters: fire the raw buffer sink first (so the live
            // transcriber can start its conversion while we're still
            // downmixing for disk), then extract / write / RMS / level.
            if let bufferSink, let format = queueFormat,
               let sample = Self.wrapAudioBufferListAsSampleBuffer(
                   bufferList: inInputData,
                   format: format
               ) {
                bufferSink(sample)
            }
            guard let (samples, format) = Self.extractMonoFloat32(
                bufferList: inInputData,
                streamDescription: queueFormat?.streamDescription.pointee
            ) else { return }
            let level = Self.rms(samples: samples)

            let wasFirst = firstFlag.withLock { seen -> Bool in
                guard !seen else { return false }
                seen = true
                return true
            }
            if wasFirst {
                NSLog("[Dictator] MeetingSystem: first audio buffer — format=\(format.sampleRate)/\(format.channelCount), frames=\(samples.count), rmsLevel=\(level)")
            }

            Task { @MainActor [weak self] in
                self?.write(samples: samples, format: format, level: level)
            }
        }
        guard createErr == noErr, let procID else {
            NSLog("[Dictator] MeetingSystem: AudioDeviceCreateIOProcIDWithBlock failed: \(createErr)")
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            self.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            _ = AudioHardwareDestroyProcessTap(tapID)
            self.processTapID = AudioObjectID(kAudioObjectUnknown)
            throw NSError(
                domain: "Dictator.Meetings", code: Int(createErr),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't attach the IO proc to the aggregate device (OSStatus \(createErr))."]
            )
        }
        self.deviceProcID = procID

        // Reset the first-buffer flag before declaring the recorder running
        // so the watchdog has a clean signal. The audio queue may already
        // be racing to deliver — the lock serialises them safely.
        firstAudioBufferFlag.withLock { $0 = false }

        let startErr = AudioDeviceStart(aggID, procID)
        guard startErr == noErr else {
            NSLog("[Dictator] MeetingSystem: AudioDeviceStart failed: \(startErr)")
            _ = AudioDeviceDestroyIOProcID(aggID, procID)
            self.deviceProcID = nil
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            self.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            _ = AudioHardwareDestroyProcessTap(tapID)
            self.processTapID = AudioObjectID(kAudioObjectUnknown)
            throw NSError(
                domain: "Dictator.Meetings", code: Int(startErr),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't start the audio device (OSStatus \(startErr))."]
            )
        }

        NSLog("[Dictator] MeetingSystem: CATap IOProc started — tap=#\(tapID) aggregate=#\(aggID)")

        self.running = true
        self.startedAt = Date()
        startBringUpWatchdog()
        onReady?()
    }

    /// Arm a 5-second timer that checks whether the IOProc is actually
    /// delivering audio buffers. With CATap the historical "FaceTime is
    /// blocking us" failure mode is gone — silence here usually means
    /// nothing on the system was producing audio for the whole window,
    /// which on a meeting is unusual enough to surface.
    private func startBringUpWatchdog() {
        bringUpWatchdog?.cancel()
        bringUpWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.running else { return }
            let saw = self.firstAudioBufferFlag.withLock { $0 }
            guard !saw else { return }
            NSLog("[Dictator] MeetingSystem: no audio buffers in 5s — nothing on the system appears to be producing audio")
            self.onCaptureWarning?("Dictator hasn't seen any system audio yet. If the call is silent or you're listening on a separate device (e.g. external headphones not routed through the default output), the system track may stay empty.")
        }
    }

    struct StopResult: Sendable {
        let durationSeconds: Double
        /// True iff `system.caf` got at least one buffer written. False on
        /// a fully-silent meeting where nothing played through speakers.
        let didCaptureSystem: Bool
    }

    /// Stop the IOProc, destroy it, destroy the aggregate device, destroy
    /// the tap. Order matters — Apple's documented teardown sequence.
    /// Safe to call multiple times; second call is a no-op.
    func stop() async -> StopResult {
        guard running else { return StopResult(durationSeconds: 0, didCaptureSystem: false) }
        running = false
        bringUpWatchdog?.cancel()
        bringUpWatchdog = nil

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = deviceProcID {
                let stopErr = AudioDeviceStop(aggregateDeviceID, procID)
                if stopErr != noErr {
                    NSLog("[Dictator] MeetingSystem: AudioDeviceStop failed: \(stopErr)")
                }
                let destroyErr = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                if destroyErr != noErr {
                    NSLog("[Dictator] MeetingSystem: AudioDeviceDestroyIOProcID failed: \(destroyErr)")
                }
                deviceProcID = nil
            }
            let aggErr = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if aggErr != noErr {
                NSLog("[Dictator] MeetingSystem: AudioHardwareDestroyAggregateDevice failed: \(aggErr)")
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if processTapID != AudioObjectID(kAudioObjectUnknown) {
            let tapErr = AudioHardwareDestroyProcessTap(processTapID)
            if tapErr != noErr {
                NSLog("[Dictator] MeetingSystem: AudioHardwareDestroyProcessTap failed: \(tapErr)")
            }
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }

        let hadSystem = systemFile != nil
        systemFile = nil
        tapFormat = nil
        tapStreamDescription = nil
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return StopResult(durationSeconds: duration, didCaptureSystem: hadSystem)
    }

    // MARK: - Disk write (main actor)

    @MainActor
    private func write(samples: [Float], format: AVAudioFormat, level: Float) {
        guard running else { return }
        do {
            if systemFile == nil, let url = systemURL {
                systemFile = try Self.openFile(at: url, source: format)
            }
            if let file = systemFile {
                try Self.append(samples: samples, format: format, to: file)
            }
            lastSystemLevel = level
        } catch {
            NSLog("[Dictator] write(system) failed: \(error)")
        }
        onLevel?(0, lastSystemLevel)
    }

    // MARK: - File helpers

    /// Open a CAF (Core Audio Format) file for streaming writes. CAF is
    /// crash-safe: the `data` chunk uses a sentinel `-1` length so a
    /// truncated file is still fully decodable. AAC in MP4/M4A is the
    /// opposite — the `moov` atom only lands on close, so a mid-recording
    /// crash leaves an unreadable container. Trade-off is size (Float32
    /// mono ~700 MB/hour) for 100% recoverability.
    private static func openFile(at url: URL, source: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func append(samples: [Float], format: AVAudioFormat, to file: AVAudioFile) throws {
        // Build a non-interleaved Float32 mono buffer at the source rate.
        // AVAudioFile.write transparently resamples to the file's target
        // rate if needed.
        guard let sourceMono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: sourceMono, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src -> Void in
                memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
            }
        }
        try file.write(from: buffer)
    }

    // MARK: - PCM extraction (off-main)

    /// Pull mono Float32 samples + the source format out of an
    /// `AudioBufferList` delivered by CATap. The tap is configured stereo
    /// global Float32, but we tolerate either interleaved or non-interleaved
    /// layouts (the ASBD's `kAudioFormatFlagIsNonInterleaved` says which).
    /// Returns `nil` on any shape we can't handle — the cycle is dropped.
    private nonisolated static func extractMonoFloat32(
        bufferList: UnsafePointer<AudioBufferList>,
        streamDescription: AudioStreamBasicDescription?
    ) -> ([Float], AVAudioFormat)? {
        guard let asbd = streamDescription else { return nil }
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat else { return nil }
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard !abl.isEmpty else { return nil }

        let frameCount: Int
        if isNonInterleaved {
            // One buffer per channel; each buffer holds `frameCount` Float32s.
            frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        } else {
            // Single interleaved buffer of `frameCount * channels` Float32s.
            frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        }
        guard frameCount > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        let invChannels = 1 / Float(channels)

        if isNonInterleaved {
            // Each AudioBuffer is one channel.
            mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                if channels == 1, let raw = abl[0].mData {
                    let src = raw.assumingMemoryBound(to: Float.self)
                    memcpy(base, src, frameCount * MemoryLayout<Float>.size)
                    return
                }
                for c in 0..<channels {
                    guard c < abl.count, let raw = abl[c].mData else { continue }
                    let src = raw.assumingMemoryBound(to: Float.self)
                    for f in 0..<frameCount {
                        let s = src[f] * invChannels
                        if c == 0 { base[f] = s } else { base[f] += s }
                    }
                }
            }
        } else {
            guard let raw = abl[0].mData else { return nil }
            let src = raw.assumingMemoryBound(to: Float.self)
            mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                if channels == 1 {
                    memcpy(base, src, frameCount * MemoryLayout<Float>.size)
                    return
                }
                for f in 0..<frameCount {
                    var sum: Float = 0
                    let frameStart = f * channels
                    for c in 0..<channels { sum += src[frameStart + c] }
                    base[f] = sum * invChannels
                }
            }
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        return (mono, format)
    }

    private nonisolated static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var v: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &v, vDSP_Length(samples.count))
        }
        return min(1, max(0, sqrtf(v) * 2.5))
    }

    // MARK: - CMSampleBuffer wrapping

    /// Wrap an `AudioBufferList` into a `CMSampleBuffer` so the existing
    /// `@Sendable (CMSampleBuffer) -> Void` sink contract is preserved.
    /// The live transcriber drops system buffers in v1, but the wrap keeps
    /// the future "live both tracks" upgrade trivial — and means no other
    /// caller needs to change shape.
    ///
    /// Copies the PCM bytes into a fresh `CMBlockBuffer` (the lifetime of
    /// `inInputData` only spans the IOProc cycle, so we can't ship the
    /// pointer through to a downstream consumer). For long meetings the
    /// copy cost is negligible — a single 10 ms cycle at 48 kHz stereo
    /// Float32 is 3840 bytes. Returns `nil` on any failure; the sink is
    /// then skipped for this cycle.
    private nonisolated static func wrapAudioBufferListAsSampleBuffer(
        bufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> CMSampleBuffer? {
        var asbd = format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        let formatErr = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard formatErr == noErr, let formatDesc else { return nil }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard !abl.isEmpty else { return nil }

        // Total bytes + frame count. Interleaved == single buffer of all
        // channels; non-interleaved == sum of every channel's buffer.
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }

        let bytesPerFrame = Int(asbd.mBytesPerFrame) > 0
            ? Int(asbd.mBytesPerFrame)
            : MemoryLayout<Float>.size * (isNonInterleaved ? 1 : channels)

        var totalBytes = 0
        for b in abl { totalBytes += Int(b.mDataByteSize) }
        guard totalBytes > 0 else { return nil }

        let frameCount: Int
        if isNonInterleaved {
            // bytesPerFrame describes one channel here, so per-channel-bytes
            // / bytesPerFrame gives frames.
            frameCount = Int(abl[0].mDataByteSize) / bytesPerFrame
        } else {
            frameCount = totalBytes / bytesPerFrame
        }
        guard frameCount > 0 else { return nil }

        // Allocate and populate a CMBlockBuffer with the PCM bytes. For
        // interleaved that's a straight copy; for non-interleaved we
        // concatenate channel buffers end-to-end — CMSampleBuffer happily
        // describes either layout via the ASBD's flags.
        var blockBuffer: CMBlockBuffer?
        let blockErr = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard blockErr == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var offset = 0
        for b in abl {
            guard let src = b.mData, b.mDataByteSize > 0 else { continue }
            let n = Int(b.mDataByteSize)
            let replaceErr = CMBlockBufferReplaceDataBytes(
                with: src,
                blockBuffer: blockBuffer,
                offsetIntoDestination: offset,
                dataLength: n
            )
            guard replaceErr == kCMBlockBufferNoErr else { return nil }
            offset += n
        }

        // No meaningful timing info from the HAL cycle. The live transcriber
        // doesn't read timestamps off the buffer — it just looks at the PCM
        // — so an invalid PTS is fine. If a future consumer needs real
        // timestamps we can derive them from `inNow`'s mHostTime.
        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        var timingArray = [timing]
        // Non-interleaved buffers have implicit "1 frame per sample" sizing
        // (the size table is the same for every sample so CMSampleBuffer
        // accepts entryCount=0). Interleaved buffers need an explicit
        // bytes-per-frame entry.
        var sampleSizeArray: [Int] = [bytesPerFrame]
        let createErr: OSStatus
        if isNonInterleaved {
            createErr = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(frameCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingArray,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        } else {
            createErr = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: CMItemCount(frameCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timingArray,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSizeArray,
                sampleBufferOut: &sampleBuffer
            )
        }
        guard createErr == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - CoreAudio property reads

    /// Translate a UNIX PID to its CoreAudio process object ID via
    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`. Returns `nil` if
    /// the process hasn't appeared in the HAL's process list (which happens
    /// before a process has ever produced audio — Dictator only does in
    /// rare error chimes, so the lookup can legitimately miss).
    private static func translatePIDToAudioProcessObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inPID = pid
        var objectID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &inPID) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard err == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private static func readTapStreamDescription(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var sizeErr = AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &dataSize)
        guard sizeErr == noErr, dataSize >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw NSError(domain: "Dictator.Meetings", code: Int(sizeErr),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't size tap format (OSStatus \(sizeErr))"])
        }
        var value = AudioStreamBasicDescription()
        sizeErr = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &value)
        guard sizeErr == noErr else {
            throw NSError(domain: "Dictator.Meetings", code: Int(sizeErr),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read tap format (OSStatus \(sizeErr))"])
        }
        return value
    }

    private static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioDeviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
        guard err == noErr, value != AudioObjectID(kAudioObjectUnknown) else {
            throw NSError(domain: "Dictator.Meetings", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read default system output device (OSStatus \(err))"])
        }
        return value
    }

    private static func readDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else {
            throw NSError(domain: "Dictator.Meetings", code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read device UID (OSStatus \(err))"])
        }
        return uid as String
    }

    // MARK: - Aggregate device cleanup

    /// Enumerate every audio device on the system, find any whose UID starts
    /// with our aggregate prefix, and destroy them. Defensive cleanup —
    /// macOS does eventually reap orphaned aggregates on logout, but if a
    /// crashed Dictator session leaks one we want it gone the next time the
    /// recorder spins up, not accumulating across launches.
    static func sweepStaleAggregates() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var err = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize)
        guard err == noErr, dataSize > 0 else { return }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        err = devices.withUnsafeMutableBufferPointer { ptr -> OSStatus in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, ptr.baseAddress!)
        }
        guard err == noErr else { return }
        for dev in devices {
            guard let uid = try? readDeviceUID(deviceID: dev) else { continue }
            guard uid.hasPrefix(aggregateUIDPrefix) else { continue }
            NSLog("[Dictator] MeetingSystem: reaping stale aggregate device \(uid)")
            let destroyErr = AudioHardwareDestroyAggregateDevice(dev)
            if destroyErr != noErr {
                NSLog("[Dictator] MeetingSystem: failed to destroy stale aggregate \(uid): \(destroyErr)")
            }
        }
    }

    private static let audioQueue = DispatchQueue(label: "Dictator.MeetingAudio.catap", qos: .userInitiated)
}
