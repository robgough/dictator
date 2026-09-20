import SwiftUI

/// Where a journal entry is up to, in the two places the window shows it: the
/// record button in the sidebar, and the entry arriving on the page.
///
/// The middle states — transcribing, then whichever style passes the journal's
/// mode runs — are shared with ordinary dictation, so everything here is gated
/// on `Pipeline.isJournalInFlight`. A dictation into Safari must not draw a
/// ghost entry on today's page.
enum JournalCapturePhase: Equatable {
    /// Mic asked for, not yet producing samples. Seconds on Bluetooth.
    case warmingUp
    case recording(level: Float)
    /// Recorded, and now being turned into an entry. The label matches the HUD
    /// word for word — the same work is being reported in two places and they
    /// shouldn't disagree.
    case working(String, symbol: String)

    @MainActor
    static func current(_ pipeline: Pipeline) -> JournalCapturePhase? {
        guard pipeline.isJournalInFlight else { return nil }
        switch pipeline.state {
        case .warmingUp:
            return .warmingUp
        case .recording(let level, _, _):
            return .recording(level: level)
        case .transcribing:
            return .working("Transcribing", symbol: "waveform.badge.magnifyingglass")
        case .readingScreen:
            return .working("Checking spellings", symbol: "textformat.abc.dottedunderline")
        case .formatting:
            return .working("Formatting", symbol: "sparkles")
        case .fixingGrammar:
            return .working("Polishing", symbol: "text.badge.checkmark")
        case .restructuring:
            return .working("Paragraphs", symbol: "list.bullet.indent")
        case .translating:
            return .working("Translating", symbol: "globe")
        default:
            return nil
        }
    }

    var isRecording: Bool {
        switch self {
        case .warmingUp, .recording: return true
        case .working: return false
        }
    }
}

/// The entry you are speaking, drawn where it is going to land.
///
/// This exists because of what the window felt like without it: you spoke,
/// the page didn't change, and there was nothing to say the words were still
/// on their way. An entry takes a few seconds to transcribe and polish, and
/// for those seconds the page should show it coming.
struct JournalIncomingEntry: View {
    let phase: JournalCapturePhase
    let pipeline: Pipeline

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt = Date()

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // The time it will carry, in the same gutter the finished entry
            // will use — so the page doesn't jump when it lands.
            Text(Self.timeFormatter.string(from: startedAt))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.hudMint.opacity(0.6))
                .frame(width: 42, alignment: .leading)

            HStack(spacing: 10) {
                content
                Spacer(minLength: 8)
                controls
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.hudMint.opacity(0.07), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.hudMint.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .onReceive(tick) { _ in elapsed = Date().timeIntervalSince(startedAt) }
        .onAppear { startedAt = Date() }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .warmingUp:
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.hudMint)
                    .frame(width: 7, height: 7)
                    .opacity(0.35)
                Text("Connecting to the microphone…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .recording(let level):
            HStack(spacing: 9) {
                Circle()
                    .fill(Color.hudMint)
                    .frame(width: 7, height: 7)
                Waveform(level: level, tint: .hudMint, barCount: 34, height: 16)
                    .frame(width: 150)
                Text(timestamp)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .working(let label, let symbol):
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.hudMint)
                Text("\(label)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if phase.isRecording {
                Button("Stop") { pipeline.finishJournal() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.hudMint)
                    .controlSize(.small)
                    .help("Stop and file this entry")
            }
            Button {
                pipeline.cancelInFlight()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(phase.isRecording ? "Discard this recording" : "Stop and discard")
        }
    }

    private var timestamp: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The sidebar's footer: the one button that starts an entry.
///
/// It lives here rather than in the toolbar because it is the window's primary
/// action and it works whatever day is on screen — the page on the right is
/// then only ever the journal itself. Recording from a past day quietly moves
/// to today first, since today is the only day an entry can be written to.
struct JournalRecordButton: View {
    @Environment(AppState.self) private var state
    @State private var store = JournalStore.shared

    private var pipeline: Pipeline { state.pipeline }
    private var phase: JournalCapturePhase? { JournalCapturePhase.current(pipeline) }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if let phase {
                    active(phase)
                } else {
                    idle
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: phase)
    }

    private var idle: some View {
        VStack(spacing: 5) {
            Button {
                store.selectToday()
                pipeline.startJournal()
            } label: {
                Label("Record Entry", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.hudMint)
            .controlSize(.large)
            // Not while an ordinary dictation is running somewhere else —
            // `startRecording` would refuse anyway, and a live-looking button
            // that does nothing is worse than a dim one.
            .disabled(pipeline.state.isActive)

            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func active(_ phase: JournalCapturePhase) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                switch phase {
                case .warmingUp:
                    Circle().fill(Color.hudMint).frame(width: 7, height: 7).opacity(0.35)
                    Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .recording(let level):
                    Circle().fill(Color.hudMint).frame(width: 7, height: 7)
                    Waveform(level: level, tint: .hudMint, barCount: 22, height: 14)
                case .working(let label, _):
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("\(label)…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                if phase.isRecording {
                    Button("Stop") { pipeline.finishJournal() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.hudMint)
                        .frame(maxWidth: .infinity)
                }
                Button(phase.isRecording ? "Discard" : "Cancel") { pipeline.cancelInFlight() }
                    .frame(maxWidth: phase.isRecording ? nil : .infinity)
            }
            .controlSize(.regular)
        }
    }

    private var hint: String {
        state.settings.journalTriggerMode == .keyboardShortcut
            ? "Or use the journal hotkey from any app"
            : "Or use the journal trigger from any app"
    }
}
