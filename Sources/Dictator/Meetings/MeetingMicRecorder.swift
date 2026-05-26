import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia

/// Captures mic audio for a meeting via AVCaptureSession and writes it
/// directly to a CAF file as the buffers arrive. Runs alongside the
/// `MeetingAudioRecorder` (SCStream system audio) on its own capture
/// session so the two tracks are independent.
///
/// Why a separate recorder and not SCStream's `.microphone` output?
/// SCK delivered the mic buffers on this test Mac but the on-disk file
/// stayed empty — likely a format / format-flag mismatch SCK takes
/// silently. AVCaptureSession is the exact path the dictation flow uses
/// every day and is known to work, so we route the mic track through it.
///
/// Writes LinearPCM Float32 mono to a `.caf` file at the device's native
/// sample rate. CAF is crash-safe (its data chunk uses a "-1 = read to
/// end" length sentinel); a truncated file from a Dictator crash is still
/// fully decodable up to the last buffer that hit disk.
@MainActor
final class MeetingMicRecorder {
    private let outputQueue = DispatchQueue(label: "Dictator.MeetingMic.output", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var forwarder: MicSampleForwarder?
    private var file: AVAudioFile?
    private var running = false

    private(set) var fileURL: URL?
    /// True once at least one buffer made it to disk.
    private(set) var didCapture: Bool = false

    /// 0…1 RMS reported on the main actor for every captured buffer.
    var onLevel: (@MainActor (Float) -> Void)?

    init() {}

    /// Build a capture session against the user's preferred input device
    /// (falls back to system default) and start writing. Throws on
    /// permission denied or no input device. Matches the dictation flow's
    /// device resolution so a meeting picks up the same Yeti / AirPods /
    /// whatever the user already chose for dictation.
    func start(at url: URL, preferredDevice: AudioDevice?) async throws {
        guard !running else { return }
        self.fileURL = url
        try? FileManager.default.removeItem(at: url)
        didCapture = false

        guard let device = Self.resolveCaptureDevice(preferred: preferredDevice) else {
            throw NSError(
                domain: "Dictator.Meetings", code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No microphone available."]
            )
        }

        let forwarder = MicSampleForwarder { [weak self] sampleBuffer in
            guard let processed = Self.processSampleBuffer(sampleBuffer) else { return }
            Task { @MainActor [weak self] in
                self?.write(samples: processed.mono, sampleRate: processed.sampleRate, level: processed.level)
            }
        }

        let queue = outputQueue
        try await Task.detached(priority: .userInitiated) { [weak self] in
            let session = AVCaptureSession()
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw NSError(
                    domain: "Dictator.Meetings", code: -11,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't add \(device.localizedName) to the meeting mic session."]
                )
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            // Force the output to Float32 PCM — without this AVCapture picks
            // whatever the device prefers (commonly Int16), and our
            // `assumingMemoryBound(to: Float.self)` then reinterprets the
            // Int16 bytes as floats and produces ~1e34-amplitude garbage
            // that Parakeet can't transcribe.
            output.audioSettings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            output.setSampleBufferDelegate(forwarder, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw NSError(
                    domain: "Dictator.Meetings", code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't attach audio output for meeting mic."]
                )
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()

            await self?.adopt(session: session, forwarder: forwarder)
        }.value
    }

    private func adopt(session: AVCaptureSession, forwarder: MicSampleForwarder) {
        self.session = session
        self.forwarder = forwarder
        self.running = true
    }

    /// Stop capture and close the file. Safe to call multiple times.
    func stop() async {
        guard running else { return }
        running = false
        let s = session
        session = nil
        forwarder = nil
        file = nil
        if let s {
            await Task.detached(priority: .userInitiated) {
                s.stopRunning()
            }.value
        }
    }

    @MainActor
    private func write(samples: [Float], sampleRate: Double, level: Float) {
        guard running, let url = fileURL else { return }
        do {
            if file == nil {
                file = try Self.openFile(at: url, sampleRate: sampleRate)
            }
            guard let file else { return }
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let dst = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src -> Void in
                    memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
                }
            }
            try file.write(from: buffer)
            didCapture = true
        } catch {
            NSLog("[Dictator] MeetingMicRecorder write failed: \(error)")
        }
        onLevel?(level)
    }

    private static func openFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private struct Processed {
        let mono: [Float]
        let sampleRate: Double
        let level: Float
    }

    private nonisolated static func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Processed? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return nil }

        // The output was configured for Float32 PCM in `start`; if a device
        // ever overrides that, drop the buffer instead of reinterpreting
        // the bytes as floats.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat, asbd.mBitsPerChannel == 32 else { return nil }

        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return nil }
        let totalFloats = totalLength / MemoryLayout<Float>.size
        guard totalFloats >= frameCount * channels else { return nil }

        let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            let buf = UnsafeBufferPointer(start: floats, count: frameCount)
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                memcpy(dst.baseAddress!, buf.baseAddress!, frameCount * MemoryLayout<Float>.size)
            }
        } else {
            // Interleaved frame-major layout: f0c0 f0c1 f1c0 f1c1 …
            let buf = UnsafeBufferPointer(start: floats, count: frameCount * channels)
            let invChannels = 1 / Float(channels)
            mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                for f in 0..<frameCount {
                    var sum: Float = 0
                    let frameStart = f * channels
                    for c in 0..<channels { sum += buf[frameStart + c] }
                    base[f] = sum * invChannels
                }
            }
        }

        var rms: Float = 0
        mono.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(mono.count))
        }
        let level = min(1, max(0, sqrtf(rms) * 2.5))
        return Processed(mono: mono, sampleRate: sampleRate, level: level)
    }
}

extension MeetingMicRecorder {
    /// Mirrors `AudioRecorder.resolveCaptureDevice(preferred:)`. The
    /// "System default" sentinel and any fall-through resolve to whatever
    /// macOS has set as the current default input.
    fileprivate nonisolated static func resolveCaptureDevice(preferred: AudioDevice?) -> AVCaptureDevice? {
        guard let preferred else { return AVCaptureDevice.default(for: .audio) }
        if preferred.isSystemDefault { return AVCaptureDevice.default(for: .audio) }
        return AVCaptureDevice(uniqueID: preferred.uid) ?? AVCaptureDevice.default(for: .audio)
    }
}

private final class MicSampleForwarder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
