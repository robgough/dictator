import SwiftUI
import AppKit

/// Dictation → Microphone: which input Dictator listens to, in what order,
/// and a one-click test that shows what the active ASR engine actually heard.
struct MicrophonePane: View {
    @State private var manager = AudioDeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MicTestCard(manager: manager)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Priority order")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    // Real devices only — the System default sentinel is
                    // always "connected" by design, but counting it would
                    // make the ratio confusing ("3 of 3 connected" when the
                    // user has 2 real mics plugged in).
                    let realDevices = manager.knownDevices.filter { !$0.isSystemDefault }
                    let connectedCount = realDevices.filter { manager.isConnected($0.uid) }.count
                    Text("\(connectedCount) of \(realDevices.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                deviceList

                SectionFootnote("Drag to reorder; the top connected device wins.")
                if manager.activeInputIsBluetooth() {
                    // Bluetooth input forces macOS into the HFP call profile:
                    // mono 16 kHz and a 2–5 s warmup before buffers arrive.
                    // Users blame Dictator for both, so name the cause — but
                    // only when it's actually the active device.
                    SectionFootnote("Bluetooth mics use call-quality audio and start slowly.")
                }
            }
        }
    }

    @ViewBuilder private var deviceList: some View {
        if manager.knownDevices.isEmpty {
            ContentUnavailableView(
                "No input devices yet",
                systemImage: "mic.slash",
                description: Text("Plug in a microphone, then click Refresh.")
            )
            // Matches the populated list's minHeight (260) so the pane
            // doesn't jump when the first device appears.
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            )
        } else {
            // Anything ranked below "System default" never wins — the
            // sentinel always counts as connected. Visually dim those rows
            // so the user can see at a glance that they're effectively dead
            // in the running order.
            let sentinelIndex = manager.knownDevices.firstIndex(where: { $0.isSystemDefault }) ?? manager.knownDevices.count
            let unreachableUIDs = Set(manager.knownDevices.dropFirst(sentinelIndex + 1).map(\.uid))
            List {
                ForEach(manager.knownDevices) { device in
                    DeviceRow(
                        device: device,
                        connected: manager.isConnected(device.uid),
                        isUnreachable: unreachableUIDs.contains(device.uid)
                    ) {
                        manager.forget(uid: device.uid)
                    }
                    .listRowSeparator(.visible)
                }
                .onMove { source, destination in
                    manager.move(from: source, to: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

/// Combines the active-input header (device name, Refresh) with an explicit
/// test recording: capture, transcribe, and show what the active ASR engine
/// heard. That answers the question a live meter only hinted at ("is my mic
/// working?") *and* tells the user how their voice is being decoded.
///
/// Side-benefit: no continuous AVAudioEngine running while Settings is open.
/// A live meter's engine fought `AudioRecorder` for the input device on
/// single-client mics (Yeti / Bluetooth) and caused occasional hangs at
/// hotkey press.
private struct MicTestCard: View {
    let manager: AudioDeviceManager

    @Environment(AppState.self) private var state
    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    @State private var liveLevel: Float = 0
    @State private var lastResult: String?
    @State private var lastError: String?

    private enum Phase: Equatable {
        case idle
        case warmingUp
        case recording
        case transcribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE INPUT")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(manager.activeInputDeviceName())
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    manager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            testRow

            if let result = lastResult {
                resultBlock(result)
            } else if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .onAppear { wireUpRecorder() }
        .onDisappear {
            // If the user navigates away mid-test, drop whatever is
            // captured so the engine isn't stuck holding the mic.
            recorder.cancelStart()
            _ = recorder.stop()
        }
    }

    @ViewBuilder private var testRow: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(phase == .warmingUp || phase == .transcribing)
            .keyboardShortcut(.defaultAction)
            .help("Records a few seconds and shows what the active engine transcribes.")

            switch phase {
            case .idle:
                EmptyView()
            case .warmingUp:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting microphone…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .recording:
                Waveform(level: liveLevel)
                    .frame(maxWidth: .infinity)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing with \(engineLabel)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func resultBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("HEARD VIA \(engineLabel.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var buttonTitle: String {
        switch phase {
        case .idle: return lastResult == nil ? "Test microphone" : "Test again"
        case .warmingUp: return "Connecting…"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing…"
        }
    }

    private var buttonIcon: String {
        switch phase {
        case .idle: return "mic.fill"
        case .warmingUp: return "antenna.radiowaves.left.and.right"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform.badge.magnifyingglass"
        }
    }

    private var engineLabel: String {
        switch state.settings.transcriptionEngine {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    private func wireUpRecorder() {
        recorder.onLevel = { level in liveLevel = level }
        recorder.onReady = {
            // Mic is genuinely capturing; flip from warmingUp to recording.
            if phase == .warmingUp { phase = .recording }
        }
        recorder.onStartFailed = { error in
            phase = .idle
            lastResult = nil
            lastError = error.localizedDescription
        }
        recorder.onUnexpectedStop = { msg in
            phase = .idle
            lastResult = nil
            lastError = msg
        }
    }

    private func toggle() {
        switch phase {
        case .idle:
            lastResult = nil
            lastError = nil
            liveLevel = 0
            phase = .warmingUp
            recorder.start()
        case .recording:
            let samples = recorder.stop()
            // Match Pipeline's threshold (< 0.5 s at 16 kHz) — anything
            // shorter is almost certainly a misclick rather than speech.
            guard samples.count >= 8_000 else {
                phase = .idle
                lastError = "Too short — speak for at least a second."
                return
            }
            phase = .transcribing
            Task { await runTranscription(samples: samples) }
        case .warmingUp, .transcribing:
            break
        }
    }

    private func runTranscription(samples: [Float]) async {
        let settings = state.settings
        let engine: any ASREngine
        let modelID: String
        switch settings.transcriptionEngine {
        case .whisper:
            engine = TranscriptionServiceHolder.shared
            modelID = settings.whisperModelID
        case .parakeet:
            engine = ParakeetServiceHolder.shared
            modelID = settings.parakeetModelID
        }
        do {
            try await engine.ensureLoaded(modelID: modelID)
            let text = try await engine.transcribe(samples: samples, modelID: modelID)
            lastError = nil
            lastResult = text.isEmpty ? "(no speech detected)" : text
            phase = .idle
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            lastResult = nil
            phase = .idle
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let connected: Bool
    /// Ranked below the System default sentinel, so it would never be
    /// chosen — the sentinel always counts as connected and short-circuits
    /// the priority walk. Rendered dimmed so the user can spot it at a
    /// glance and drag it above the sentinel if they want it to matter.
    let isUnreachable: Bool
    let forget: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(connected: connected)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if isUnreachable {
                        Text("Below System default — never used")
                    } else if device.isSystemDefault {
                        Text("Follows the macOS Sound preferences")
                    } else {
                        if let manufacturer = device.manufacturer, !manufacturer.isEmpty, manufacturer != "Apple" {
                            Text(manufacturer)
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        Text(connected ? "Connected" : "Last seen \(Self.relative(device.lastSeen))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // The System default sentinel is structural — there's no
            // meaningful "forget" action, so the button just disappears
            // for that row.
            if !device.isSystemDefault {
                Button {
                    forget()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hovering ? Color.red.opacity(0.85) : .secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help("Forget this device")
                .onHover { hovering = $0 }
            }
        }
        .padding(.vertical, 6)
        .opacity(isUnreachable ? 0.45 : 1)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
