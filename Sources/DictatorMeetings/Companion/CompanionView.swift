import SwiftUI

/// What the companion shows: the time and Stop, whether both sides are being
/// heard, how the talking is split, the key points, the last few things the
/// live notes caught, and a field to jot something into the pad — the parts
/// of the recording screen worth a glance mid-call, and nothing else.
struct CompanionView: View {
    static let width: CGFloat = 340

    @Environment(MeetingsAppState.self) private var state
    @Bindable var session: MeetingSession
    /// Reports the content's height so the controller can size the panel —
    /// see `CompanionController` for why it isn't done by the hosting view.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var jot = ""
    @FocusState private var jotFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 16) {
                SourceMeter(label: "You", level: levels.mic, tint: .accentColor, heard: session.micHeard)
                SourceMeter(label: "Them", level: levels.system, tint: .indigo,
                            heard: session.systemHeard, waitingHint: systemWaitingHint)
            }
            if let coach = session.coachEngine {
                CoachMetricsStrip(engine: coach)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Key points", systemImage: "checklist")
                    CoachChecklistPanel(engine: coach, compact: true)
                }
            }
            if !recentNotes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Just noted", systemImage: "sparkles", tint: .purple)
                    ForEach(recentNotes, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(Color.purple.opacity(0.55)).frame(width: 5, height: 5)
                            inlineMarkdownText(line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            jotField
            footer
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        // A near-opaque surface of its own rather than glass. Glass takes its
        // colour from what's behind the panel, which here is always someone's
        // video: murky over a dark call, busy over a bright one, and never
        // the same twice. This reads the same over anything.
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        // The panel may briefly be taller than the content while it catches
        // up; keep the content at the top rather than centred in it.
        .frame(maxHeight: .infinity, alignment: .top)
        // The panel is never the key window — it mustn't take focus from the
        // call — so AppKit would draw every control as inactive: a grey Stop,
        // a dimmed record dot. It's always the thing being used, so draw it so.
        .environment(\.controlActiveState, .key)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(isWarming ? Color.orange : Color.red)
                .symbolEffect(.pulse, options: .repeating, isActive: !isWarming)
            Text(elapsed)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(session.meta.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(role: .destructive, action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isWarming)
        }
    }

    private var jotField: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line").foregroundStyle(.secondary)
            TextField("Jot something down…", text: $jot)
                .textFieldStyle(.plain)
                .focused($jotFocused)
                .onSubmit(addJot)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .help("Adds a line to this meeting's pad. Start it with ! to add a key point instead.")
    }

    private var footer: some View {
        HStack {
            Button("Open in window") {
                state.pendingShowLive = true
                NSApp.activate(ignoringOtherApps: true)
                state.openMeetingsWindowAction?()
            }
            .buttonStyle(.link)
            Spacer()
            Button("Hide") { state.companionDismissed = true }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
                .help("Hide the companion for this meeting. It comes back next time.")
        }
        .font(.caption)
    }

    private func sectionLabel(_ title: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
    }

    // MARK: - Behaviour

    /// Appends to the pad as its own line — through `updatePad`, so a line
    /// starting with `!` becomes a key point exactly as it would typed there.
    private func addJot() {
        let line = jot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        var pad = session.padText
        if !pad.isEmpty, !pad.hasSuffix("\n") { pad += "\n" }
        session.updatePad(pad + line + "\n")
        jot = ""
    }

    /// Stopping from here hands the window the meeting it just finished, so
    /// the review — who spoke, then the notes — is what's waiting.
    private func stop() {
        state.pendingShowLive = true
        NSApp.activate(ignoringOtherApps: true)
        state.openMeetingsWindowAction?()
        let modelID = state.settings.parakeetModelID
        Task { await session.stopRecording(parakeetModelID: modelID) }
    }

    /// The last three points the live notes caught, newest last.
    private var recentNotes: [String] {
        guard let markdown = session.notesAccumulator?.liveNotes, !markdown.isEmpty else { return [] }
        let bullets = MarkdownBlock.parse(markdown).filter { $0.kind == .bullet && $0.indent == 0 }.map(\.text)
        return Array(bullets.suffix(3))
    }

    private var isWarming: Bool {
        switch session.state {
        case .warmingUp, .stopping: return true
        default: return false
        }
    }

    private var levels: (mic: Float, system: Float) {
        if case .recording(_, let mic, let sys) = session.state { return (mic, sys) }
        return (0, 0)
    }

    private var systemWaitingHint: String? {
        guard case .recording(let elapsed, _, _) = session.state else { return nil }
        guard !session.systemHeard, session.micHeard, elapsed > 6 else { return nil }
        return "No call audio yet"
    }

    private var elapsed: String {
        guard case .recording(let t, _, _) = session.state else { return "00:00" }
        let s = Int(t.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
