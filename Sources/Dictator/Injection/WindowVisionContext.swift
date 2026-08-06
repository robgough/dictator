import FoundationModels
import CoreGraphics
import Foundation

/// On-device *vision* context for dictation. Captures the focused window (see
/// `WindowImageCapture`) and asks Apple's on-device foundation model — which
/// gained image input in macOS 27 — to read back the proper nouns and
/// distinctive terms visible in it. Those terms are merged into the same
/// `documentTerms` list the Accessibility path produces, so they flow into the
/// formatter prompt as a spelling reference AND drive the deterministic
/// diacritic restoration (`DocumentTerms.restoreDiacritics`) — no new prompt
/// channel, no new trust surface.
///
/// It complements, never replaces, the AX text reads: vision reaches names that
/// live *outside* the field being typed into, and works in apps that don't
/// expose their text to Accessibility at all. Entirely on-device and free — the
/// system model is shared across apps, so there's no weight to download and no
/// in-process memory cost. Best-effort throughout: every failure path yields an
/// empty term list, never an error, so a missed capture just means "no vision
/// seasoning this run".
enum WindowVisionContext {
    /// Deadline for the dictation *terms* pass. Output is a short list, so the
    /// capture + inference finishes in ~1s; this just bounds a wedged capture.
    private static let timeoutSeconds: Double = 4.0

    /// Deadline for the assistant *describe* pass. Much longer than the terms
    /// deadline: this generates a paragraph-scale briefing (a description plus
    /// the visible text), which on the on-device model can take many seconds on
    /// a text-dense window like an email — 4s reliably cut it off mid-generation
    /// and the assistant saw nothing. It runs concurrently with the instruction
    /// recording, so most of this is hidden; the ceiling only bites a genuinely
    /// slow read. Past it, the turn proceeds without vision rather than hang.
    private static let readbackTimeoutSeconds: Double = 18.0

    /// True only when the on-device model can actually accept an image on this
    /// machine: macOS 27+, Apple Intelligence usable, and the `.vision`
    /// capability advertised. Vision was added to the small ~3 B Core model in
    /// macOS 27 (verified by probing the framework — the API exists in the SDK
    /// AND the shipped model reports the capability). Gates both the Settings
    /// toggle's visibility and the pipeline kick-off, so older OSes and
    /// ineligible Macs simply never run it.
    ///
    /// Always false when built against an SDK without FoundationModels' image
    /// input (see `FOUNDATION_MODELS_VISION` in project.yml) — the code that
    /// would use it isn't compiled in, so every entry point below must agree.
    @MainActor
    static var isSupported: Bool {
        #if !FOUNDATION_MODELS_VISION
        return false
        #else
        guard #available(macOS 27.0, *) else { return false }
        guard AppleFoundationAvailability.isUsable else { return false }
        guard SystemLanguageModel.default.capabilities.contains(.vision) else { return false }
        // The model advertising `.vision` is NOT sufficient: the Swift API that
        // actually feeds it an image — `Attachment(_ cgImage:orientation:)` — was
        // added to FoundationModels *after* the first macOS 27.0 seeds. On an OS
        // build that predates it (e.g. 26A5378j) the model still reports `.vision`
        // true, but the initializer symbol is absent from the shipped framework,
        // so the moment the pipeline constructs `Attachment(image)` dyld fails to
        // bind it and the process crashes (SIGSEGV inside FoundationModels — not a
        // catchable error). `#available(macOS 27.0, *)` can't distinguish this: the
        // seed reports version 27.0. So probe for the symbol directly and treat
        // vision as unsupported when it isn't there. Self-healing: the probe flips
        // to true automatically once the user's OS ships the initializer.
        return imageAttachmentAPIAvailable
        #endif
    }

    /// True when the running OS actually exports `Attachment(_ cgImage:orientation:)`.
    /// Probed via `dlsym` against the process's default search order (RTLD_DEFAULT)
    /// — a lookup only, so it never constructs the attachment and thus never trips
    /// the missing-symbol crash. The mangled name is exactly the symbol our own
    /// `Attachment(image)` call sites reference, so a positive probe guarantees the
    /// real call will bind. Computed once; the answer can't change within a launch.
    private static let imageAttachmentAPIAvailable: Bool = {
        // _$s… with the leading underscore is dyld's C prefix; dlsym wants it dropped.
        let mangled = "$s16FoundationModels10AttachmentVA2A05ImageC7ContentVRszrlE_11orientationACyAEGSo10CGImageRefa_So0G19PropertyOrientationVSgtcfC"
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(rtldDefault, mangled) != nil
    }()

    /// Capture the focused window and return the distinctive terms read from it,
    /// or an empty list on any failure (unsupported, no permission, no window,
    /// model refusal, timeout). Nonisolated — the heavy work is async capture +
    /// model inference; callers run it off the main actor (a detached task), so
    /// neither the screenshot nor the inference touches the dictation hot path.
    static func captureFocusedWindowTerms() async -> [String] {
        #if !FOUNDATION_MODELS_VISION
        return []
        #else
        guard #available(macOS 27.0, *) else { return [] }
        return await withDeadline(seconds: timeoutSeconds, fallback: [String]()) {
            guard let image = await WindowImageCapture.captureFocusedWindow() else { return [] }
            return await extractTerms(from: image)
        }
        #endif
    }

    #if FOUNDATION_MODELS_VISION
    @available(macOS 27.0, *)
    private static func extractTerms(from image: CGImage) async -> [String] {
        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0.0,
            maximumResponseTokens: 160
        )
        do {
            let response = try await session.respond(options: options) {
                "Read this screenshot of the window the user is dictating into."
                Attachment(image)
            }
            return parseTerms(response.content)
        } catch {
            // Refusals (guardrails firing on arbitrary on-screen content) and any
            // other model error just mean no terms this run — never surfaced.
            NSLog("[Dictator] Window vision: model declined or failed — no terms.")
            return []
        }
    }
    #endif

    /// The model is asked for a *spelling reference*, not a transcription —
    /// short output keeps it fast (a full read-back costs many more generation
    /// tokens than a tight list). Framed as data extraction with an explicit
    /// "only what's visible / NONE if nothing" rule so it doesn't invent terms
    /// or narrate. The deterministic consumers downstream are tolerant of the
    /// odd stray term (the formatter is told never to add words the dictation
    /// doesn't say; the diacritic restore only touches accented proper nouns).
    private static let systemPrompt = """
    You extract spelling references from a screenshot. Look ONLY at text actually \
    visible in the image. Output a single comma-separated list of the proper nouns \
    that appear there — people's names, place names, company and product names, and \
    distinctive technical terms or identifiers (camelCase words, acronyms, code \
    symbols) — each spelled EXACTLY as shown, including capitalisation and any \
    accents (Siobhán, Zürich, Kraków). Do not include ordinary words, whole \
    sentences, punctuation, commentary, or anything that is not visible as text in \
    the image. If there are no such terms, output the single word NONE.
    """

    /// Splits the model's comma/newline-separated reply into clean terms.
    /// Defensive against the model wrapping the list in a sentence, returning
    /// NONE, or decorating items with bullets/quotes: anything that isn't a
    /// short, letter-bearing, ≤3-word token is dropped. Deduped
    /// case-insensitively and capped to the same ceiling the AX miner uses.
    private static func parseTerms(_ raw: String) -> [String] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.uppercased() != "NONE" else { return [] }

        let trimSet = CharacterSet(charactersIn: ".;:•*-–—\"'`()[]")
        var seen: Set<String> = []
        var terms: [String] = []
        for piece in cleaned.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let term = piece
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: trimSet)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, term.count <= 40,
                  term.split(separator: " ").count <= 3,   // a name/term, not a clause
                  term.contains(where: { $0.isLetter })     // not pure punctuation/digits
            else { continue }
            if seen.insert(term.lowercased()).inserted { terms.append(term) }
            if terms.count >= DocumentTerms.maxTerms { break }
        }
        // Count only — never the terms themselves (they're the user's content).
        NSLog("[Dictator] Window vision: read %d distinctive term(s) from the focused window.", terms.count)
        return terms
    }

    /// Runs `operation`, giving up with an empty list after `seconds`. Whichever
    /// child finishes first wins; the loser is cancelled. Keeps a hung capture
    /// or inference from ever delaying the dictation.
    private static func withDeadline<T: Sendable>(
        seconds: Double,
        fallback: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            for await first in group {
                if let first { return first }   // operation produced a result
                return fallback                  // timeout fired first
            }
            return fallback
        }
    }

    // MARK: - Assistant read-back (description + terms)

    /// One vision pass for Assistant Mode: a text briefing of the focused window
    /// the assistant can reason over, plus the distinctive terms mined from it
    /// for spelling. Both come from a single capture + inference.
    struct VisionReadback: Sendable {
        /// The vision model's briefing of the focused window — a short
        /// description of what's shown (it can see images and layout, not just
        /// text) followed by the salient visible text. Capped. Fed to the
        /// assistant as the read-only [SCREEN] block (see `assistantPromptBlock`).
        let content: String
        /// Distinctive terms mined deterministically from `content` (same miner
        /// the Accessibility path uses) — names/products/identifiers for the
        /// assistant's spelling reference.
        let terms: [String]
        /// Why `content` is empty, when it is — surfaced in the result window's
        /// per-turn context banner so an empty read is debuggable rather than a
        /// silent "nothing". nil on success.
        var failureReason: String? = nil
        static let empty = VisionReadback(content: "", terms: [])
        static func failed(_ reason: String) -> VisionReadback {
            VisionReadback(content: "", terms: [], failureReason: reason)
        }
    }

    /// Max characters of the vision briefing kept for the assistant. Roomier
    /// than the dictation terms path — this carries a short description plus the
    /// salient on-screen text, and the assistant's text engine (MLX) has a wide
    /// context window — but still bounded so a text-dense window can't crowd out
    /// the conversation.
    private static let maxContentChars = 2400

    /// Capture the focused window and have the vision model *describe* it (plus
    /// mine terms) for Assistant Mode. This is the first stage of a two-stage
    /// pipeline: Apple's on-device vision model — the only on-device model that
    /// can see an image — turns the screenshot into a text briefing (what's on
    /// screen + the key words), which the user's normal assistant engine (which
    /// may be MLX and can't see images) then reasons over. Empty on any failure;
    /// runs concurrently with the instruction recording.
    static func captureFocusedWindowReadback() async -> VisionReadback {
        #if !FOUNDATION_MODELS_VISION
        return .failed("needs macOS 27")
        #else
        guard #available(macOS 27.0, *) else { return .failed("needs macOS 27") }
        return await withDeadline(seconds: readbackTimeoutSeconds,
                                  fallback: VisionReadback.failed("timed out")) {
            guard let image = await WindowImageCapture.captureFocusedWindow() else {
                return .failed("couldn't capture the window")
            }
            return await extractReadback(from: image)
        }
        #endif
    }

    #if FOUNDATION_MODELS_VISION
    @available(macOS 27.0, *)
    private static func extractReadback(from image: CGImage) async -> VisionReadback {
        let session = LanguageModelSession(instructions: Instructions(readbackSystemPrompt))
        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0.0,
            maximumResponseTokens: 512
        )
        do {
            let response = try await session.respond(options: options) {
                "Brief me on what is shown in this screenshot of the window the user is working in."
                Attachment(image)
            }
            let content = String(
                response.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxContentChars)
            )
            guard !content.isEmpty, content.uppercased() != "NONE" else {
                return .failed("the model saw no usable text")
            }
            let terms = DocumentTerms.distinctiveTerms(in: content)
            // Counts only — never the briefing text (it's the user's screen).
            NSLog("[Dictator] Window vision (assistant): described %d chars, %d term(s) from the focused window.",
                  content.count, terms.count)
            return VisionReadback(content: content, terms: terms)
        } catch {
            NSLog("[Dictator] Window vision (assistant): model declined or failed — no description.")
            return .failed("the vision model declined")
        }
    }
    #endif

    /// Asks the vision model to be the assistant's eyes: a short description of
    /// what the window shows (it can see images and layout, not just text),
    /// followed by the salient visible text verbatim so the downstream assistant
    /// has the exact words and spellings. Lets the assistant answer "describe
    /// what I'm looking at" and act on non-text content, while the second stage
    /// still does the actual reasoning.
    private static let readbackSystemPrompt = """
    You are the eyes of an assistant that cannot see the screen. Looking at this \
    screenshot of the window the user is working in, produce a compact briefing \
    the assistant can rely on:
    - First, one or two sentences describing what the window is and what it shows \
    — the app or kind of content, and any images, diagrams, charts, or notable UI, \
    not just text.
    - Then the meaningful visible text — headings, the message or document body, \
    sender and recipient names, labels and their values — preserving the wording \
    and spelling exactly, including any accents.
    Skip chrome like toolbar icons, menu bars, and window controls. Describe only \
    what is actually visible; never invent. If the window is essentially empty, \
    output the single word NONE.
    """
}
