import SwiftUI

// MARK: - Meeting Design Kit
//
// Shared SwiftUI building blocks for the Meetings UI. Three goals:
//   1. Dynamic Type — every size here is derived from a SEMANTIC font
//      (.caption2, .caption, …) so the OS scales chrome with the user's text
//      size. No hardcoded point sizes; the few fixed geometry values
//      (`MeetingMetrics`) are intentionally chrome, not text.
//   2. ONE chip style — `MeetingChip` / `.meetingChip(tone:)` give every
//      pill the same fill, padding, capsule and typography. Tone picks the
//      colour family; the geometry never changes.
//   3. Colour-blind support — `SpeakerBadge` distinguishes speakers by BOTH
//      colour AND a distinct SHAPE, via a deterministic colour→shape map over
//      the 7-colour `MeetingProcessor.speakerPalette` (+ a fixed "me" shape).
//
// BUILD-SAFETY NOTES (don't reintroduce these as new symbols — they already
// exist elsewhere in the module and would clash):
//   • `.notesSurface()`  — View extension in MarkdownNotesView.swift. Reuse it.
//   • `Color(hex:)`      — file-private initializer in TranscriptView.swift.
//                          DON'T add another; this kit uses `Color(meetingHex:)`.
//   • `speakerColor(_:)` — global hex→Color helper in MarkdownNotesView.swift.
//   • `Color.assistantIndigo` — file-private accent in TranscriptView.swift.

// MARK: - Shared metrics

/// Fixed chrome geometry shared across the meeting kit. These are *chrome*
/// values (capsule corner radii, gaps between chips, the small inset on a card)
/// — deliberately not text, so they don't scale with Dynamic Type. Anything
/// that carries text scales via the semantic fonts below instead.
enum MeetingMetrics {
    /// Corner radius for the `.notesSurface()`-style cards and code blocks.
    static let cardCornerRadius: CGFloat = 10
    /// Horizontal padding inside a chip capsule.
    static let chipHPadding: CGFloat = 8
    /// Vertical padding inside a chip capsule.
    static let chipVPadding: CGFloat = 3
    /// Gap between the colour/shape badge and a chip's label.
    static let chipInnerSpacing: CGFloat = 6
    /// Gap between sibling chips in a row.
    static let chipRowSpacing: CGFloat = 8
    /// Inline badge edge length used where the old ~8pt speaker dot sat. Kept
    /// fixed so it reads as a glyph next to scalable text without ballooning.
    static let inlineBadgeSize: CGFloat = 9
    /// Slightly larger badge for the labelled speaker chip.
    static let labelledBadgeSize: CGFloat = 11
}

/// Semantic fonts for the kit. Centralised so every chip/badge label uses the
/// same scalable type ramp — change it here, change it everywhere.
enum MeetingFonts {
    /// The standard chip label — small, semibold, scales with Dynamic Type.
    static let chipLabel: Font = .caption2.weight(.semibold)
    /// A slightly larger label for the labelled speaker chip.
    static let speakerLabel: Font = .caption.weight(.semibold)
}

// MARK: - Hex → Color (kit-local, differently named on purpose)

extension Color {
    /// Parse a "#RRGGBB" hex string (as stored on `MeetingMeta.Speaker`).
    ///
    /// Deliberately a *labelled* initializer (`meetingHex:`) rather than
    /// `init?(hex:)` — TranscriptView.swift already declares a file-private
    /// `Color(hex:)`, and adding a second one visible across the module would
    /// make the call ambiguous wherever both are in scope. This name never
    /// collides. Returns `.accentColor` is left to the caller; this is failable.
    init?(meetingHex: String) {
        var trimmed = meetingHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

// MARK: - Consistent chip / pill

/// Visual tone for a `MeetingChip`. Picks the colour family only — every tone
/// shares the same capsule, padding and font, so chips read as one system.
enum MeetingChipTone {
    /// Muted grey — counts, metadata, non-status chips.
    case neutral
    /// Brand indigo — the assistant / "smart" affordances.
    case accent
    /// Orange — warnings, suspicious states.
    case warning
    /// Orange, used specifically for the "Draft" / not-final pill.
    case draft

    /// The chip's foreground (text + icon) colour.
    var foreground: Color {
        switch self {
        case .neutral: return .secondary
        case .accent:  return Self.indigo
        case .warning: return .orange
        case .draft:   return .orange
        }
    }

    /// The base colour the capsule fill is tinted from.
    var fillBase: Color {
        switch self {
        case .neutral: return .secondary
        case .accent:  return Self.indigo
        case .warning: return .orange
        case .draft:   return .orange
        }
    }

    /// Capsule fill opacity — neutral sits quieter than the coloured tones so a
    /// row of metadata chips doesn't compete with a status chip.
    var fillOpacity: Double {
        switch self {
        case .neutral: return 0.12
        case .accent:  return 0.16
        case .warning: return 0.16
        case .draft:   return 0.18
        }
    }

    /// Brand indigo (≈#5E5CE6) — matches the meeting assistant accent. Kept
    /// local to the kit (TranscriptView's `Color.assistantIndigo` is file-private
    /// there, so it isn't visible here).
    static let indigo = Color(red: 0.369, green: 0.361, blue: 0.902)
}

/// The one true meeting chip: a small capsule label with shared fill, padding,
/// capsule shape and semantic typography. Optional leading SF Symbol, optional
/// trailing SF Symbol (e.g. a warning glyph). Uppercasing is opt-in for status
/// pills like "Draft".
///
/// Prefer this (or the `.meetingChip(tone:)` modifier for arbitrary content)
/// over hand-rolling `Capsule().fill(...)` so every pill stays consistent.
struct MeetingChip: View {
    let text: String
    var tone: MeetingChipTone = .neutral
    var systemImage: String? = nil
    var trailingSystemImage: String? = nil
    var uppercased: Bool = false

    init(
        _ text: String,
        tone: MeetingChipTone = .neutral,
        systemImage: String? = nil,
        trailingSystemImage: String? = nil,
        uppercased: Bool = false
    ) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
        self.trailingSystemImage = trailingSystemImage
        self.uppercased = uppercased
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
                .textCase(uppercased ? .uppercase : nil)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
            }
        }
        .meetingChip(tone: tone)
    }
}

extension View {
    /// Apply the shared chip chrome (font, padding, capsule fill, foreground)
    /// to *any* content. Use this when a chip needs custom inner layout that
    /// `MeetingChip` can't express (e.g. an editable speaker chip with a badge
    /// and a sparkles glyph). Plain `MeetingChip` covers the text-only case.
    func meetingChip(tone: MeetingChipTone = .neutral) -> some View {
        self
            .font(MeetingFonts.chipLabel)
            .padding(.horizontal, MeetingMetrics.chipHPadding)
            .padding(.vertical, MeetingMetrics.chipVPadding)
            .background(Capsule().fill(tone.fillBase.opacity(tone.fillOpacity)))
            .foregroundStyle(tone.foreground)
    }
}

// MARK: - Speaker badge (colour + shape, colour-blind safe)

/// A speaker identity glyph that encodes the speaker BOTH by colour AND by a
/// distinct shape — so two speakers stay tellable apart in greyscale or for a
/// colour-blind viewer. The shape is derived deterministically from the
/// speaker's palette colour (or `isMe`), so the same speaker always gets the
/// same shape across the app and across reprocesses.
///
/// Replaces the bare `Circle().fill(...).frame(width: 8, height: 8)` dot. Use
/// `.inline` where that dot sat; `.labelled(name)` for a small chip-like token.
struct SpeakerBadge: View {
    /// The speaker's "#RRGGBB" colour (from `MeetingMeta.Speaker.colorHex`).
    let colorHex: String
    /// True for the local user — pinned to one distinctive shape regardless of
    /// colour, so "me" is instantly recognisable.
    let isMe: Bool
    var variant: Variant = .inline

    enum Variant {
        /// Bare glyph sized to replace the old ~8pt speaker dot.
        case inline
        /// Glyph + name, laid out like a token. Pass the display name.
        case labelled(String)
    }

    init(colorHex: String, isMe: Bool, variant: Variant = .inline) {
        self.colorHex = colorHex
        self.isMe = isMe
        self.variant = variant
    }

    /// Convenience: build straight from a `MeetingMeta.Speaker`.
    init(speaker: MeetingMeta.Speaker, variant: Variant = .inline) {
        self.colorHex = speaker.colorHex
        self.isMe = speaker.isMe
        self.variant = variant
    }

    private var color: Color { Color(meetingHex: colorHex) ?? .accentColor }
    private var symbol: String { SpeakerShape.symbol(colorHex: colorHex, isMe: isMe) }

    var body: some View {
        switch variant {
        case .inline:
            glyph(size: MeetingMetrics.inlineBadgeSize)
                .accessibilityHidden(true)
        case .labelled(let name):
            HStack(spacing: 4) {
                glyph(size: MeetingMetrics.labelledBadgeSize)
                Text(name)
                    .font(MeetingFonts.speakerLabel)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, MeetingMetrics.chipHPadding)
            .padding(.vertical, MeetingMetrics.chipVPadding)
            .background(Capsule().fill(color.opacity(0.16)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(name)
        }
    }

    /// The filled SF Symbol, sized in points so it sits as a compact glyph
    /// beside scalable text. `imageScale` lets it nudge with Dynamic Type while
    /// the frame keeps it from overwhelming a chip row.
    @ViewBuilder
    private func glyph(size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(color)
            .frame(width: size + 3, height: size + 3)
    }
}

/// Deterministic colour → shape (SF Symbol) mapping for speaker badges. The 7
/// `MeetingProcessor.speakerPalette` colours are paired 1:1 with 7 visually
/// distinct filled symbols; "me" and the legacy "other" colour get their own
/// fixed shapes. Anything off-palette falls back by hashing the hex, so a
/// recoloured speaker still gets a stable, distinct shape.
enum SpeakerShape {
    /// The brand-blue "me" colour. Kept here so the kit doesn't depend on a
    /// private constant elsewhere.
    static let meColorHex = "#5B9BD5"
    /// The legacy "other"/diarizer-failed colour (also palette index 0).
    static let otherColorHex = "#ED7D31"

    /// Fixed shape for the local user — a filled person so "me" is unmistakable.
    static let meSymbol = "person.fill"

    /// The 7 palette colours, lowercased, in the same order as
    /// `MeetingProcessor.speakerPalette`. Mirrored here (not referenced) so the
    /// kit has no build-order dependency on the processor; keep in sync if the
    /// processor palette ever changes.
    static let paletteHexes: [String] = [
        "#ed7d31",  // orange  → circle
        "#70ad47",  // green   → square
        "#a5a5a5",  // grey    → triangle
        "#9966cc",  // purple  → diamond
        "#e15554",  // red     → hexagon
        "#4b89dc",  // sky blue→ pentagon
        "#f4b400",  // amber   → seal/star
    ]

    /// One distinct filled SF Symbol per palette slot. Chosen to read clearly
    /// at ~9–11pt and to stay distinguishable in greyscale.
    static let paletteSymbols: [String] = [
        "circle.fill",
        "square.fill",
        "triangle.fill",
        "diamond.fill",
        "hexagon.fill",
        "pentagon.fill",
        "seal.fill",
    ]

    /// Resolve a speaker's badge symbol. `isMe` wins; otherwise we match the
    /// palette slot by hex; off-palette colours hash to a stable slot so they
    /// still get a distinct, repeatable shape.
    static func symbol(colorHex: String, isMe: Bool) -> String {
        if isMe { return meSymbol }
        let key = normalize(colorHex)
        if key == normalize(meColorHex) { return meSymbol }
        if let idx = paletteHexes.firstIndex(of: key) {
            return paletteSymbols[idx]
        }
        // Off-palette (user recoloured): stable hash → a palette shape.
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return paletteSymbols[hash % paletteSymbols.count]
    }

    private static func normalize(_ hex: String) -> String {
        var t = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.hasPrefix("#") { t = "#" + t }
        return t
    }
}
