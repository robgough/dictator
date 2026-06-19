import SwiftUI

// Literal RGB tints for the non-blue island accents. We deliberately don't use
// SwiftUI's semantic colours (`.indigo`, `.purple`, `.pink`, `.teal`,
// `.orange`) here: those are dynamic and re-resolve under the visual-effect
// view's vibrancy appearance, which itself shifts with the window content
// behind the HUD — so otherwise the icons and status text would drift in
// colour as the user moved the HUD over different apps. The HUD's blue
// reuses `Color.brandBlue` (defined in BrandColors.swift).
private extension Color {
    static let hudIndigo = Color(red: 0.369, green: 0.361, blue: 0.902) // ~#5E5CE6
    static let hudPurple = Color(red: 0.749, green: 0.353, blue: 0.949) // ~#BF5AF2
    static let hudPink   = Color(red: 1.0,   green: 0.216, blue: 0.373) // ~#FF375F
    static let hudTeal   = Color(red: 0.392, green: 0.824, blue: 1.0)   // ~#64D2FF
    static let hudOrange = Color(red: 1.0,   green: 0.624, blue: 0.039) // ~#FF9F0A
}

struct DictationIslandContent: View {
    @Environment(AppState.self) private var state
    @State private var deviceManager = AudioDeviceManager.shared
    @State private var hovering = false

    /// The last non-idle pipeline state, kept so the retract has content to
    /// carry: when dictation finishes the pipeline snaps to `.idle` in the
    /// same beat the island starts sliding up, and rendering the live state
    /// made the text vanish instantly (and collapsed the shape under the
    /// in-flight offset animation). While the pipeline is live we render it
    /// directly — this cache is read only during `.idle`, i.e. the retract.
    @State private var lastNonIdleState: PipelineState?

    private var renderState: PipelineState {
        let live = state.pipeline.state
        if case .idle = live { return lastNonIdleState ?? live }
        return live
    }

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // No background here — this renders inside the island's black
            // shape (IslandView owns the chrome). The forced-dark scheme up
            // there resolves .primary/.secondary light-on-black; the literal
            // accent colours above hold their values on black just as they
            // did over the old material.
            .overlay(alignment: .topTrailing) {
                if hovering && state.pipeline.state.canCancel {
                    Button {
                        state.pipeline.cancelInFlight()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.18), value: hovering)
            .animation(.snappy(duration: 0.25), value: stateKey)
            .onHover { hovering = $0 }
            .onChange(of: liveStateKey) { _, _ in
                let live = state.pipeline.state
                if case .idle = live { return }
                // Cache on case transitions only — `.done`'s text is fixed
                // at the moment it's entered, which is exactly what the
                // retract should carry. (Per-level `.recording` churn keeps
                // the same key, so this doesn't fire per meter tick.)
                lastNonIdleState = live
            }
    }

    @ViewBuilder private var content: some View {
        switch renderState {
        case .idle:
            EmptyView()
        case .capturingSelection:
            StatusRow(icon: "selection.pin.in.out", title: "Reading selection", accent: .hudIndigo)
        case .warmingUp(let isAssistant):
            // Bluetooth mics (AirPods, Beats, …) need 2–5 s for HFP profile
            // negotiation before AVAudioEngine actually starts producing
            // buffers. Surface that explicitly so the user doesn't think
            // they've been recording for the past few seconds.
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isAssistant ? Color.hudIndigo : Color.brandBlue)
                    .font(.system(size: 22, weight: .semibold))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting microphone")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(deviceManager.activeInputDeviceName())
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView()
                    .controlSize(.small)
            }
        case .recording(let level, let isAssistant, let interim):
            let isContinuation = isAssistant && state.pipeline.nextAssistantIsContinuation
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    if isAssistant {
                        Image(systemName: isContinuation ? "bubble.left.and.bubble.right.fill" : "wand.and.stars")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.hudIndigo)
                            .font(.system(size: 18, weight: .semibold))
                    } else {
                        RecordingDot()
                    }
                    Waveform(level: level, tint: isAssistant ? .hudIndigo : .brandBlue)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(isContinuation ? "Following up" : (isAssistant ? "Assistant" : "Listening"))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(isAssistant ? Color.hudIndigo : .primary)
                        Text(isContinuation
                             ? "Continuing the conversation"
                             : (isAssistant ? "Speak your instruction" : deviceManager.activeInputDeviceName()))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Mode chip — dictation only. Modes don't apply to
                        // Assistant Mode (separate flow, separate prompt). The
                        // "Tab → next" suffix only renders when Tab cycling will
                        // actually work — i.e. when Accessibility is granted so
                        // the CGEventTap can swallow Tab before it inserts a tab
                        // character into the focused app. Without AX we'd be
                        // promising a feature we can't deliver.
                        if !isAssistant {
                            let canCycle = TextInjector.hasAccessibilityPermission()
                            ModeChip(
                                name: state.pipeline.currentMode.name,
                                nextName: canCycle ? state.pipeline.nextCycleMode?.name : nil
                            )
                        }
                        // Same Esc-cancel discoverability hint as the
                        // StatusRow states. Sits below the mode chip so it
                        // doesn't separate the chip from its subtitle.
                        Text("Press Esc to cancel")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                    .frame(maxWidth: 200, alignment: .trailing)
                }
                // The preview well is RESERVED for the whole recording (with
                // a quiet placeholder until words arrive) rather than
                // inserted when text lands — appearing mid-recording resized
                // the island around the waveform row, which read as the
                // whole HUD jumping. Gated on the interim setting so users
                // who've turned the preview off never see the empty well.
                if state.settings.realtimeInterimEnabled {
                    InterimPreview(text: interim)
                }
            }
        case .transcribing:
            StatusRow(icon: "waveform.badge.magnifyingglass", title: "Transcribing", accent: .brandBlue)
        case .formatting:
            StatusRow(icon: "sparkles", title: "Formatting", accent: .hudPurple)
        case .fixingGrammar:
            StatusRow(icon: "text.badge.checkmark", title: "Tidying grammar", accent: .hudPink)
        case .restructuring:
            StatusRow(icon: "list.bullet.indent", title: "Structuring", accent: .hudTeal)
        case .assisting:
            StatusRow(icon: "wand.and.stars", title: "Thinking", accent: .hudIndigo)
        case .compacting:
            StatusRow(icon: "archivebox", title: "Summarising earlier turns", accent: .hudIndigo)
        case .done(let text, let pasted, let note):
            HStack(spacing: 14) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, pasted ? Color.brandBlue : Color.hudOrange)
                    .font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .lineLimit(note == nil ? 2 : 1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    if let note {
                        Text(note)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.hudOrange)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.hudOrange)
                    .font(.system(size: 22))
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Content-swap animation key, derived from what's RENDERED (so the
    /// retract doesn't animate a swap to empty when the live state hits
    /// `.idle`). `liveStateKey` tracks the actual pipeline for the cache.
    private var stateKey: String { Self.key(for: renderState) }
    private var liveStateKey: String { Self.key(for: state.pipeline.state) }

    private static func key(for s: PipelineState) -> String {
        switch s {
        case .idle: "idle"
        case .capturingSelection: "capturingSelection"
        case .warmingUp: "warmingUp"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .formatting: "formatting"
        case .fixingGrammar: "fixingGrammar"
        case .restructuring: "restructuring"
        case .assisting: "assisting"
        case .compacting: "compacting"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

private struct StatusRow: View {
    let icon: String
    let title: String
    let accent: Color
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
                .font(.system(size: 22, weight: .semibold))
                .scaleEffect(pulse ? 1.08 : 0.96)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                // Escape-cancel discoverability hint. Surfaced on every
                // "waiting" state — same set the EscapeCancelMonitor
                // listens on — so when something runs slow (or wedges)
                // the user already knows how to bail.
                Text("Press Esc to cancel")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .onAppear { pulse = true }
    }
}

/// Compact pill that names the active dictation mode, plus a "Tab → <next>"
/// suffix when the cycle has more than one entry. Renders inline in the HUD's
/// trailing column during `.recording` (dictation flow only).
private struct ModeChip: View {
    let name: String
    let nextName: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brandBlue)
            if let nextName {
                Text("⇥")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text(nextName)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.brandBlue.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.brandBlue.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.top, 1)
    }
}

/// Multi-line preview of the in-flight streaming transcript, shown in a
/// fixed-height well (~3 lines) reserved for the whole recording so the HUD
/// doesn't resize as text builds up. The transcript wraps and fills top-down;
/// once it overflows three lines it scrolls, keeping the newest words pinned to
/// the bottom while older lines slide up out of view. Filling a few stable
/// lines reads far calmer than the old single-line view, where every snapshot
/// re-decode slid the whole line sideways — worse the longer you spoke.
///
/// The well is styled as a subtle bordered "draft" zone so it isn't mistaken
/// for the final transcript that actually gets pasted.
private struct InterimPreview: View {
    let text: String

    /// Vertical room per line of the preview font (~11 pt SF Rounded). Three
    /// slots → the well shows three lines; beyond that the ScrollView scrolls.
    private static let lineSlot: CGFloat = 14.5
    private static let visibleLines: CGFloat = 3
    private static let bottomAnchor = "interim-preview-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "ellipsis.bubble")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("PREVIEW")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .tracking(0.4)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Word-level animated transcript, tuned for the realtime
                        // engine's constant whole-buffer re-decodes: unchanged
                        // words slide, replaced words cross-fade, new words fade
                        // in — only what changed moves. The trailing cursor
                        // doubles as the "listening" placeholder before the
                        // first words land.
                        StreamingTranscript(target: text)
                            .font(.system(size: 11, weight: .regular, design: .rounded).italic())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Bottom inset so the newest (bottom-pinned) line clears
                        // the well's border instead of sitting flush against it,
                        // and so italic descenders don't clip at the scroll edge.
                        Color.clear
                            .frame(height: 5)
                            .id(Self.bottomAnchor)
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: Self.lineSlot * Self.visibleLines)
                .onChange(of: text) { _, _ in
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.brandBlue)
            .frame(width: 10, height: 10)
            .shadow(color: Color.brandBlue.opacity(0.6), radius: on ? 10 : 2)
            .opacity(on ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
