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
    /// Deadline for the dictation *terms* pass on Apple's model. Output is a
    /// short list and the on-device model answers in ~1s, so this just bounds a
    /// wedged capture.
    private static let appleTimeoutSeconds: Double = 4.0

    /// Deadline for the same pass on an MLX vision model. Far longer, because
    /// an MLX VLM is far slower at this: measured 4–7s for Gemma 4 12B on a
    /// 1024px window grab, against Apple's ~0.8s. That is affordable because
    /// the read runs *concurrently with the recording* — it starts when the
    /// hotkey goes down and is only needed once transcription finishes — so
    /// almost all of it hides behind the user's own speech. The ceiling exists
    /// for the case where it doesn't: past it, the dictation proceeds with no
    /// vision terms rather than waiting.
    ///
    /// The pass can also end early without hitting this at all — it runs at
    /// `.background` priority, so the formatting pass cancels it on arrival
    /// (see `MLXLLMService.readImage`). A short dictation therefore loses its
    /// vision terms rather than delaying the paste, which is the right trade.
    /// Raised well past the measured 4–7s on purpose. This ceiling costs the
    /// user nothing when it's generous: the read runs at `.background`, so the
    /// formatting pass cancels it the moment it needs the model. The deadline
    /// is only a backstop against a wedged capture, and setting it near the
    /// measured time just loses terms on a busy machine for no benefit.
    private static let mlxTimeoutSeconds: Double = 25.0

    /// Deadline for the assistant *describe* pass. Much longer than the terms
    /// deadline: this generates a paragraph-scale briefing (a description plus
    /// the visible text), which on the on-device model can take many seconds on
    /// a text-dense window like an email — 4s reliably cut it off mid-generation
    /// and the assistant saw nothing. It runs concurrently with the instruction
    /// recording, so most of this is hidden; the ceiling only bites a genuinely
    /// slow read. Past it, the turn proceeds without vision rather than hang.
    private static let readbackTimeoutSeconds: Double = 18.0

    /// Read-back deadline and token budget for an MLX vision model, which is a
    /// different animal from Apple's.
    ///
    /// Measured on Gemma 4 12B reading a 1024px window: **10.7–11.5s** for the
    /// 512-token briefing, on an idle machine and a visually simple window. A
    /// text-dense one — an email, the case this feature exists for — produces a
    /// much longer briefing and takes correspondingly longer. The 18s ceiling
    /// above was sized for Apple's ~1s model and cut MLX read-backs off
    /// constantly.
    ///
    /// Raising the ceiling is the whole fix. Lowering the token budget was
    /// tried and measured and does NOT help: 512 → 320 tokens moved the time
    /// from 10.7–11.5s to 10.1–10.6s, because the model naturally writes about
    /// 300 tokens of briefing and never reaches either cap. The cost here is
    /// image *prefill*, not generation, so the only real levers are capture
    /// resolution and not doing this pass at all. A tighter cap would buy about
    /// a second on a simple window while truncating a dense one mid-sentence —
    /// dense windows being exactly what this feature is for — so the budget
    /// stays where it was.
    ///
    /// This is a stopgap. The real fix is to stop describing the screen to
    /// ourselves: when the assistant's own model can see, hand it the
    /// screenshot and let it answer in one pass instead of two, which removes
    /// this ~10s entirely rather than hiding it behind a bigger number.
    private static let mlxReadbackTimeoutSeconds: Double = 40.0

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
    /// Which model will do the reading, or nil when nothing here can.
    ///
    /// Apple's is preferred whenever it's usable: it answers in about a second
    /// against an MLX VLM's several, costs no extra resident memory (the system
    /// model is shared across apps), and needs no particular model to be loaded.
    /// The MLX path is the fallback that actually works today — as of macOS 27.0
    /// GA the OS ships no way to hand Apple's model an image at all (see
    /// `imageAttachmentAPIAvailable`), so in practice this resolves to `.mlx`
    /// or to nil.
    enum Backend: Sendable { case apple, mlx }

    @MainActor
    static var backend: Backend? {
        if appleVisionAvailable { return .apple }
        // The MLX route needs the *resident* model to be one we've verified can
        // read an image — `visionCapable` in the catalog, which is set from a
        // real test and not from the checkpoint advertising a vision config.
        if MLXLLMServiceHolder.shared.canReadImages { return .mlx }
        return nil
    }

    /// True when a backend can read an image *right now*. Gates the pipeline
    /// kick-off — vision runs this instant or not at all.
    @MainActor
    static var isSupported: Bool { backend != nil }

    /// True when this Mac could do vision once everything is warmed up — used
    /// for **Settings toggle visibility only**.
    ///
    /// Deliberately not `isSupported`. That one requires a model to be resident,
    /// which is correct on the hot path and wrong in Settings: the MLX model
    /// isn't loaded until first use, so a user opening Settings straight after
    /// launch would find the toggle simply missing, then present later with no
    /// explanation. This asks the durable question instead — is the *selected*
    /// model one that can see? — so the control is stable.
    /// Why the vision toggle can't be switched on, or nil when it can.
    ///
    /// The control stays visible and disabled rather than disappearing: a
    /// setting that vanishes when you change model looks like a bug or a lost
    /// preference, and leaves you with nowhere to read *why* it's gone. The
    /// reason names the thing to change, because "unavailable" on its own just
    /// moves the puzzle.
    @MainActor
    static func unavailableReason(engine: LLMEngineKind, mlxModelID: String) -> String? {
        if isConfigurable(engine: engine, mlxModelID: mlxModelID) { return nil }
        let capable = visionCapableModelNames
        switch engine {
        case .none:
            return "Needs a language model. Choose one in Settings → Models."
        case .apple:
            return "Apple's model can't take images on this macOS. Switch to \(capable) in Settings → Models."
        case .mlx:
            let name = ModelCatalog.llm(id: mlxModelID)?.displayName ?? "The selected model"
            return "\(name) can't read images. Switch to \(capable) in Settings → Models."
        }
    }

    /// Human-readable list of the models that can actually do this, for the
    /// explanation above. Driven off the catalog so it can't drift out of date
    /// when a model is added or a `visionCapable` flag flips.
    @MainActor
    private static var visionCapableModelNames: String {
        let names = ModelCatalog.llmModels.filter(\.visionCapable).map(\.displayName)
        switch names.count {
        case 0: return "a model that can read images"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
    }

    @MainActor
    static func isConfigurable(engine: LLMEngineKind, mlxModelID: String) -> Bool {
        if appleVisionAvailable { return true }
        guard engine == .mlx else { return false }
        return ModelCatalog.llm(id: mlxModelID)?.visionCapable ?? false
    }

    @MainActor
    private static var appleVisionAvailable: Bool {
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
    /// A lookup only — it never constructs the attachment, so it can't trip the
    /// missing-symbol crash. Computed once; the answer can't change in a launch.
    ///
    /// **Probe via a `dlopen` handle on the framework, not `RTLD_DEFAULT`.** The
    /// obvious `dlsym(RTLD_DEFAULT, …)` cannot see FoundationModels' Swift
    /// symbols at all — it reports the framework's own `SystemLanguageModel`
    /// accessors as missing in a process that is demonstrably calling them —
    /// while resolving C symbols and Swift stdlib symbols from the same binary
    /// just fine. An earlier version of this gate used it and was therefore
    /// pinned to false forever: the feature was dead code, and would have stayed
    /// dead after Apple shipped the initializer.
    ///
    /// `sentinel` is what keeps that from recurring silently. It's a symbol we
    /// know resolves whenever the technique works, so a missing sentinel means
    /// "this probe is broken", not "the API is absent" — and we fail closed and
    /// say so, rather than quietly disabling vision for the rest of time.
    private static let imageAttachmentAPIAvailable: Bool = {
        // _$s… with the leading underscore is dyld's C prefix; dlsym wants it dropped.
        let target = "$s16FoundationModels10AttachmentVA2A05ImageC7ContentVRszrlE_11orientationACyAEGSo10CGImageRefa_So0G19PropertyOrientationVSgtcfC"
        let sentinel = "$s16FoundationModels19SystemLanguageModelC7defaultACvgZ"
        let path = "/System/Library/Frameworks/FoundationModels.framework/FoundationModels"
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        guard dlsym(handle, sentinel) != nil else {
            NSLog("[Dictator] Window vision: symbol probe is no longer valid — treating Apple vision as unavailable.")
            return false
        }
        return dlsym(handle, target) != nil
    }()

    /// Capture the focused window and return the distinctive terms read from it,
    /// or an empty list on any failure (unsupported, no permission, no window,
    /// model refusal, timeout). Nonisolated — the heavy work is async capture +
    /// model inference; callers run it off the main actor (a detached task), so
    /// neither the screenshot nor the inference touches the dictation hot path.
    static func captureFocusedWindowTerms() async -> [String] {
        guard let backend = await MainActor.run(body: { self.backend }) else { return [] }
        let deadline = backend == .apple ? appleTimeoutSeconds : mlxTimeoutSeconds
        return await withDeadline(seconds: deadline, fallback: [String]()) {
            guard let image = await WindowImageCapture.captureFocusedWindow() else { return [] }
            switch backend {
            case .apple: return await appleExtractTerms(from: image)
            case .mlx:   return await mlxExtractTerms(from: image)
            }
        }
    }

    /// Terms pass on an MLX vision model — the same prompt and the same parser
    /// as the Apple path, so the two backends are interchangeable from the
    /// pipeline's point of view. Any failure (nothing loaded, preempted by a
    /// dictation pass, model error) yields no terms, never an error.
    private static func mlxExtractTerms(from image: CGImage) async -> [String] {
        do {
            let reply = try await MLXLLMServiceHolder.shared.readImage(
                image,
                systemPrompt: systemPrompt,
                userPrompt: "Read this screenshot of the window the user is dictating into.",
                maxTokens: 160
            )
            return parseTerms(reply)
        } catch {
            NSLog("[Dictator] Window vision (MLX): no terms this run — %@", error.localizedDescription)
            return []
        }
    }

    #if FOUNDATION_MODELS_VISION
    @available(macOS 27.0, *)
    private static func appleExtractTermsImpl(from image: CGImage) async -> [String] {
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

    /// Apple-path terms read, compiled away entirely on an SDK without image
    /// input. The backend selector can only return `.apple` when both the OS and
    /// this code path are actually present, so the fallback here is unreachable
    /// in practice — it exists so the two backends share one call site.
    private static func appleExtractTerms(from image: CGImage) async -> [String] {
        #if !FOUNDATION_MODELS_VISION
        return []
        #else
        guard #available(macOS 27.0, *) else { return [] }
        return await appleExtractTermsImpl(from: image)
        #endif
    }

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

    /// What an assistant turn got from the screen.
    ///
    /// Two shapes because there are two situations. When the assistant's own
    /// model can see, there is no reason to describe the screen to ourselves
    /// first — hand over the screenshot and let it answer from the real thing.
    /// When it can't (Apple's model looked, or the assistant engine is a
    /// text-only model), someone has to turn pixels into words first.
    enum AssistantVision: Sendable {
        /// Single stage: the assistant model reads this itself.
        case image(CGImage)
        /// Two stage: a briefing written by whichever model could see.
        case briefing(VisionReadback)
    }

    /// Capture for an assistant turn, taking the single-stage route when the
    /// assistant's own model can read images.
    ///
    /// Single stage is strictly better where it applies. It removes an entire
    /// inference from the turn — measured at ~10s for Gemma 4 12B, which was
    /// the whole of the "vision times out" problem — and it drafts from the
    /// actual window rather than from a ≤2400-character summary of it, which
    /// matters most for exactly the thing people want this for: replying to a
    /// long email without selecting anything.
    ///
    /// `assistantCanSee` is the caller's judgement, because only the pipeline
    /// knows which engine will answer. Passing false is always safe — it just
    /// takes the older, slower route.
    static func captureForAssistant(assistantCanSee: Bool) async -> AssistantVision {
        guard assistantCanSee else {
            return .briefing(await captureFocusedWindowReadback())
        }
        // No deadline needed here: this is a screen grab, not an inference.
        // The cost lands inside the assistant call, where the user is already
        // waiting and can see the HUD.
        guard let image = await WindowImageCapture.captureFocusedWindow() else {
            return .briefing(.failed("couldn't capture the window"))
        }
        return .image(image)
    }

    /// Capture the focused window and have the vision model *describe* it (plus
    /// mine terms) for Assistant Mode. This is the first stage of a two-stage
    /// pipeline: Apple's on-device vision model — the only on-device model that
    /// can see an image — turns the screenshot into a text briefing (what's on
    /// screen + the key words), which the user's normal assistant engine (which
    /// may be MLX and can't see images) then reasons over. Empty on any failure;
    /// runs concurrently with the instruction recording.
    static func captureFocusedWindowReadback() async -> VisionReadback {
        guard let backend = await MainActor.run(body: { self.backend }) else {
            return .failed("no model here can read an image")
        }
        let deadline = backend == .apple ? readbackTimeoutSeconds : mlxReadbackTimeoutSeconds
        return await withDeadline(seconds: deadline,
                                  fallback: VisionReadback.failed("timed out")) {
            guard let image = await WindowImageCapture.captureFocusedWindow() else {
                return .failed("couldn't capture the window")
            }
            switch backend {
            case .apple: return await appleExtractReadback(from: image)
            case .mlx:   return await mlxExtractReadback(from: image)
            }
        }
    }

    /// Read-back on an MLX vision model. When the *assistant's own* engine is
    /// this same vision-capable model the two-stage hand-off is redundant in
    /// principle — it could look at the screenshot directly — but keeping the
    /// briefing shape means the assistant path doesn't care which backend saw
    /// the screen, and the [SCREEN] block stays one plain text channel that both
    /// engines already render.
    private static func mlxExtractReadback(from image: CGImage) async -> VisionReadback {
        do {
            let reply = try await MLXLLMServiceHolder.shared.readImage(
                image,
                systemPrompt: readbackSystemPrompt,
                userPrompt: "Brief me on what is shown in this screenshot of the window the user is working in.",
                maxTokens: 512
            )
            let content = String(
                reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxContentChars)
            )
            guard !content.isEmpty, content.uppercased() != "NONE" else {
                return .failed("the model saw no usable text")
            }
            let terms = DocumentTerms.distinctiveTerms(in: content)
            // Counts only — never the briefing text (it's the user's screen).
            NSLog("[Dictator] Window vision (MLX, assistant): described %d chars, %d term(s).",
                  content.count, terms.count)
            return VisionReadback(content: content, terms: terms)
        } catch {
            NSLog("[Dictator] Window vision (MLX, assistant): no description — %@", error.localizedDescription)
            return .failed("the vision model was interrupted or failed")
        }
    }

    /// Apple-path read-back, compiled away on an SDK without image input.
    private static func appleExtractReadback(from image: CGImage) async -> VisionReadback {
        #if !FOUNDATION_MODELS_VISION
        return .failed("needs macOS 27")
        #else
        guard #available(macOS 27.0, *) else { return .failed("needs macOS 27") }
        return await appleExtractReadbackImpl(from: image)
        #endif
    }

    #if FOUNDATION_MODELS_VISION
    @available(macOS 27.0, *)
    private static func appleExtractReadbackImpl(from image: CGImage) async -> VisionReadback {
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
