import SwiftUI

/// The two bottom-anchored HUD styles — `.pill` and `.mini` — sharing one
/// pop-up choreography. The shape sits at the bottom-centre of the panel's
/// canvas (the controller parks the canvas just above the Dock) and pops in
/// with a short rise + scale + fade rather than the island's
/// slide-from-behind-the-edge: there's no screen edge to emerge from down
/// here, and a shape sliding out of thin air above the Dock reads as a
/// glitch. Dismiss is a quick fade-and-sink.
///
/// Motion rides the transaction of the controller's `withAnimation` around
/// `context.revealed`, exactly like `IslandView`. Reduce Motion drops the
/// rise/scale and keeps the fade.
struct CompactHUDView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: HUDContext
    /// `.pill` or `.mini`. (`.island` is `IslandView`'s job; passing it here
    /// renders the pill.)
    let style: HUDStyle

    /// Room left under the shape, inside the canvas, for its drop shadow.
    /// The controller lowers the canvas by this much so the visible shape
    /// still rests exactly `HUDStyle.bottomInset` above the Dock.
    static let shadowBleed: CGFloat = 20

    /// Flips true the first time the pipeline goes live and stays true, so
    /// the dismiss animation always has content to carry away — by the time
    /// we're hiding, the pipeline is already `.idle`. Mirrors `IslandView`'s
    /// `displayMode` retention.
    @State private var shown = false
    @State private var hovering = false

    private var isMini: Bool { style == .mini }

    private var active: Bool {
        let s = state.pipeline.state
        if s.isActive { return true }
        if case .done = s { return true }
        if case .failed = s { return true }
        return false
    }

    var body: some View {
        let revealed = context.revealed
        ZStack(alignment: .bottom) {
            if shown {
                CompactHUDContent(style: style, hovering: hovering)
                    .padding(.horizontal, isMini ? 11 : 14)
                    .padding(.vertical, isMini ? 6 : 9)
                    .background(chrome)
                    .onHover { hovering = $0 }
                    .padding(.bottom, Self.shadowBleed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .offset(y: reduceMotion || revealed ? 0 : 18)
        .scaleEffect(reduceMotion || revealed ? 1 : 0.9, anchor: .bottom)
        .opacity(revealed ? 1 : 0)
        // The mini badge is always dark-on-black; the pill's material adapts
        // to the system appearance like the original HUD did.
        .transformEnvironment(\.colorScheme) { scheme in
            if isMini { scheme = .dark }
        }
        .onAppear { if active { shown = true } }
        .onChange(of: active) { _, new in
            if new { shown = true }
        }
    }

    @ViewBuilder private var chrome: some View {
        if isMini {
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        } else {
            // Rounded rect rather than a true capsule: a single row is a
            // near-capsule at this radius, and the taller two-row layout
            // (with the live preview) still reads as one card instead of
            // sprouting 40 pt semicircular ends.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        }
    }
}

/// State-by-state content for the compact styles. Same information as the
/// island, squeezed: while listening both styles are one row — glyph, meter,
/// mode — with the pill adding a two-line live preview underneath when
/// that's on; working stages are a pulsing glyph plus the stage name.
/// Hovering (only possible while the pipeline is cancellable) swaps the
/// leading glyph for a ✕ — the pointer counterpart of Esc.
///
/// Mirrors `DictationIslandContent`'s retention trick: the pipeline snaps to
/// `.idle` the instant a dictation finishes, in the same beat the dismiss
/// starts, so during `.idle` we render the last non-idle state and let it
/// fade out with its text intact.
struct CompactHUDContent: View {
    @Environment(AppState.self) private var state
    @State private var deviceManager = AudioDeviceManager.shared
    /// `.pill`, `.mini`, or `.islandSmall` (which uses the pill layout on
    /// the island's chrome). Only `.mini` changes the layout.
    let style: HUDStyle
    let hovering: Bool

    @State private var lastNonIdleState: PipelineState?

    private var isMini: Bool { style == .mini }

    private var renderState: PipelineState {
        let live = state.pipeline.state
        if case .idle = live { return lastNonIdleState ?? live }
        return live
    }

    // Type ramp per style. Everything rounded, like the island.
    private var titleFont: Font { .system(size: 12, weight: .semibold, design: .rounded) }
    private var bodyFont: Font { .system(size: isMini ? 11 : 12, weight: isMini ? .medium : .regular, design: .rounded) }
    private var subtitleFont: Font { .system(size: 9.5, weight: .medium, design: .rounded) }
    private var hintFont: Font { .system(size: 9, weight: .medium, design: .rounded) }
    private var glyphSize: CGFloat { isMini ? 13 : 16 }
    private var gap: CGFloat { isMini ? 8 : 10 }
    /// Width of the listening layout when the live preview is on (pill and
    /// small island) — the preview well and the meter row above it share
    /// it, so the row's bars stretch to exactly the well's edges.
    private static let previewWidth: CGFloat = 300

    var body: some View {
        content
            // Floor so the pill doesn't bob in height between one- and
            // two-line states.
            .frame(minHeight: isMini ? 20 : 24)
            .animation(.snappy(duration: 0.25), value: stateKey)
            .onChange(of: liveStateKey) { _, _ in
                let live = state.pipeline.state
                if case .idle = live { return }
                // Cache on case transitions only — `.done`'s text is fixed
                // at the moment it's entered, which is exactly what the
                // dismiss should carry. (Per-level `.recording` churn keeps
                // the same key, so this doesn't fire per meter tick.)
                lastNonIdleState = live
            }
    }

    @ViewBuilder private var content: some View {
        switch renderState {
        case .idle:
            EmptyView()
        case .capturingSelection:
            stage(icon: "selection.pin.in.out", title: isMini ? "Selection" : "Reading selection", accent: .hudIndigo)
        case .warmingUp(let isAssistant):
            // Bluetooth mics need a few seconds of HFP negotiation before
            // buffers flow — say so, as the island does, so the user doesn't
            // think they've been recording already. The badge says it in
            // words too: a bare antenna glyph only told people who already
            // knew what it meant that they should wait before speaking.
            HStack(spacing: gap) {
                leadingGlyph("antenna.radiowaves.left.and.right", accent: isAssistant ? .hudIndigo : .brandBlue, pulse: true)
                if isMini {
                    Text("Connecting mic…")
                        .font(bodyFont)
                        .foregroundStyle(.primary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Connecting microphone")
                            .font(titleFont)
                            .foregroundStyle(.primary)
                        Text(deviceManager.activeInputDeviceName())
                            .font(subtitleFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .clampWidth(220)
                }
                ProgressView()
                    .controlSize(.mini)
            }
        case .recording(let level, let isAssistant, let interim):
            recording(level: level, isAssistant: isAssistant, interim: interim)
        case .transcribing:
            stage(icon: "waveform.badge.magnifyingglass", title: "Transcribing", accent: .brandBlue)
        case .formatting:
            stage(icon: "sparkles", title: "Formatting", accent: .hudPurple)
        case .fixingGrammar:
            stage(icon: "text.badge.checkmark", title: "Polishing", accent: .hudPink)
        case .restructuring:
            stage(icon: "list.bullet.indent", title: "Paragraphs", accent: .hudTeal)
        case .assisting:
            stage(icon: "wand.and.stars", title: "Thinking", accent: .hudIndigo)
        case .compacting:
            stage(icon: "archivebox", title: isMini ? "Summarising" : "Summarising earlier turns", accent: .hudIndigo)
        case .done(let text, let pasted, let note):
            HStack(spacing: gap) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, pasted ? Color.brandBlue : Color.hudOrange)
                    .font(.system(size: glyphSize, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(text)
                        .font(bodyFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note, !isMini {
                        Text(note)
                            .font(subtitleFont)
                            .foregroundStyle(Color.hudOrange)
                            .lineLimit(1)
                    }
                }
                .clampWidth(isMini ? 220 : 300)
            }
        case .failed(let message):
            HStack(spacing: gap) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.hudOrange)
                    .font(.system(size: glyphSize))
                Text(message)
                    .font(bodyFont)
                    .foregroundStyle(.primary)
                    .lineLimit(isMini ? 1 : 2)
                    .clampWidth(isMini ? 240 : 300)
            }
        }
    }

    /// Listening: one row, everything on a single centre line — the dot (or
    /// assistant glyph), the meter, and the mode. No "Listening" caption:
    /// the pulsing dot and live bars already say it. In the pill with the
    /// preview on, the row takes the well's width and the bars stretch to
    /// fill the gap between dot and chip; otherwise the meter is a fixed run
    /// and the row hugs its content. The mini badge keeps the mode name up
    /// the whole time (it's the only mode feedback the badge has, and Tab
    /// cycling re-renders it in place).
    @ViewBuilder
    private func recording(level: Float, isAssistant: Bool, interim: String) -> some View {
        let isContinuation = isAssistant && state.pipeline.nextAssistantIsContinuation
        let tint: Color = isAssistant ? .hudIndigo : .brandBlue
        let previewOn = !isMini && state.settings.realtimeInterimEnabled
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: gap) {
                if isAssistant {
                    leadingGlyph(isContinuation ? "bubble.left.and.bubble.right.fill" : "wand.and.stars", accent: .hudIndigo)
                } else {
                    cancelSlot { RecordingDot() }
                }
                Waveform(
                    level: level,
                    tint: tint,
                    barCount: isMini ? 10 : (previewOn ? 22 : 14),
                    height: isMini ? 14 : 20
                )
                .frame(width: previewOn ? nil : (isMini ? 46 : 82))
                if isAssistant {
                    if !isMini {
                        Text(isContinuation ? "Following up" : "Speak your instruction")
                            .font(subtitleFont)
                            .foregroundStyle(Color.hudIndigo)
                            .lineLimit(1)
                    }
                } else if isMini {
                    Text(state.pipeline.currentMode.name)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.brandBlue)
                        .lineLimit(1)
                } else {
                    // Same Accessibility gate as the island: only promise
                    // "Tab → next" when the CGEventTap can actually swallow
                    // Tab.
                    let canCycle = TextInjector.hasAccessibilityPermission()
                    ModeChip(
                        name: state.pipeline.currentMode.name,
                        nextName: canCycle ? state.pipeline.nextCycleMode?.name : nil
                    )
                }
            }
            // Tab cycling changes the name's width; ease the shape along
            // rather than snapping.
            .animation(.snappy(duration: 0.2), value: state.pipeline.currentMode.id)
            // Two lines of live preview under the row, reserved for the
            // whole recording (as in the island) so the pill doesn't grow
            // mid-sentence. Two rather than one: the flow is pinned to its
            // newest line, so a one-line well showed a lone word right after
            // every wrap. The mini badge never shows text while listening.
            if previewOn {
                InterimPreview(text: interim, visibleLines: 2, compact: true)
            }
        }
        .frame(width: previewOn ? Self.previewWidth : nil)
    }

    /// A "working" stage: pulsing glyph + title. The pill adds the Esc hint
    /// and a spinner; the badge is glyph + one word.
    private func stage(icon: String, title: String, accent: Color) -> some View {
        HStack(spacing: gap) {
            leadingGlyph(icon, accent: accent, pulse: true)
            if isMini {
                Text(title)
                    .font(bodyFont)
                    .foregroundStyle(.primary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.primary)
                    Text("Esc to cancel")
                        .font(hintFont)
                        .foregroundStyle(.tertiary)
                }
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private func leadingGlyph(_ name: String, accent: Color, pulse: Bool = false) -> some View {
        cancelSlot {
            PulsingGlyph(name: name, accent: accent, size: glyphSize, pulse: pulse)
        }
    }

    /// The leading glyph's slot doubles as the pointer cancel target: while
    /// hovering a cancellable state it shows a ✕ instead. Fixed-size so the
    /// swap never shifts the row.
    private func cancelSlot<G: View>(@ViewBuilder glyph: () -> G) -> some View {
        CancelSlot(
            active: hovering && state.pipeline.state.canCancel,
            size: glyphSize + 4,
            glyph: glyph()
        ) {
            state.pipeline.cancelInFlight()
        }
    }

    /// Content-swap animation key, derived from what's RENDERED (so the
    /// dismiss doesn't animate a swap to empty when the live state hits
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

private struct PulsingGlyph: View {
    let name: String
    let accent: Color
    let size: CGFloat
    let pulse: Bool
    @State private var on = false

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(accent)
            .font(.system(size: size, weight: .semibold))
            .scaleEffect(pulse ? (on ? 1.08 : 0.94) : 1)
            .animation(pulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

private struct CancelSlot<G: View>: View {
    let active: Bool
    let size: CGFloat
    let glyph: G
    let cancel: () -> Void

    var body: some View {
        ZStack {
            if active {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: size, height: size)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.16), value: active)
    }
}

/// Sizes its child to the child's ideal width, capped — "shrink to fit, but
/// no wider than this". A plain `.frame(maxWidth:)` is greedy (it takes the
/// whole proposal up to the cap), which would pad every result pill out to
/// its maximum even for a three-word dictation; `.fixedSize()` goes the
/// other way and defeats the cap entirely. The child is then proposed the
/// clamped width so `lineLimit`/truncation still kick in past the cap.
private struct ClampWidth: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        let width = min(ideal.width, cap)
        let fitted = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: width, height: fitted.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private extension View {
    func clampWidth(_ cap: CGFloat) -> some View {
        ClampWidth(cap: cap) { self }
    }
}
