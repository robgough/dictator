import Foundation
import MLX
import MLXLMCommon

/// A KV cache reused across the rounds of a chat turn.
///
/// Every round of a turn re-sends the whole prompt — system block, tool
/// schemas, the conversation so far — and prefilling it is the dominant cost
/// of a tool-using turn. This keeps the computed state for the prompt we have
/// already seen, so a round that merely *extends* that prompt only pays for the
/// new tail.
///
/// Measured on Qwen 3.5 9B, chained question needing two tools, with the
/// deferred tool list that actually ships: 5.1s → 3.0s, and 3,815 → 1,337
/// tokens prefilled. The scenarios behind those numbers have three-line
/// conversations, so they understate it — the longer a real thread grows, the
/// more of each round's prompt is already cached.
///
/// Two design points that are not arbitrary:
///
/// **The baseline holds the prompt minus its final token.** That last token is
/// what seeds generation, and `TokenIterator.prepare` consumes everything it is
/// handed — so caching the *whole* prompt and then seeding generation with its
/// last token processes that token twice, shifting every position after it.
///
/// **We snapshot rather than trim.** Generation runs on a throwaway copy so the
/// baseline never contains generated tokens, which means a cancelled or
/// preempted round costs nothing and needs no rollback. That matters because
/// rollback isn't available where we need it most: Qwen 3.5's linear-attention
/// layers use `ArraysCache`, whose `isTrimmable` is false, so `trimPromptCache`
/// is a no-op on the models we recommend.
///
/// Exactly **one** copy per round. Two (baseline→working *and* working→baseline)
/// cost more than the prefill they saved once the cache grew — on a 4.4K prompt
/// that turned an 8.4s turn into 20.3s.
///
/// `@unchecked Sendable` because `[KVCache]` holds `MLXArray`s, which are not
/// `Sendable`. The discipline that makes it safe: this is only ever touched
/// inside a `ModelContainer.perform` closure, and `perform` serialises.
final class ChatPromptCache: @unchecked Sendable {
    /// Cache state holding exactly `tokens`.
    private var baseline: [KVCache]?
    /// The prompt tokens `baseline` represents.
    private var tokens: [Int] = []
    /// What this cache belongs to. Anything else invalidates it.
    private var ownerKey: String?

    /// Don't cache a prompt beyond this. A KV cache for a long thread on a 12B
    /// runs to hundreds of megabytes and the working copy doubles it, which is
    /// not a trade worth making on a 16 GB Mac that is also holding the model.
    private static let maxCachedTokens = 16_384

    /// Drop everything. Called when the model changes or is unloaded — the
    /// cached state is meaningless against different weights.
    func reset() {
        baseline = nil
        tokens = []
        ownerKey = nil
    }

    /// What a round starts from: the cache to generate into, and what it cost
    /// to get there.
    ///
    /// The cache is a throwaway — the caller generates into it and discards it.
    struct Prepared {
        let cache: [KVCache]
        /// Tokens actually prefilled this round. The rest of the prompt came
        /// out of the baseline, which is the entire point of this type.
        let prefilled: Int
        /// Wall-clock seconds those tokens took.
        ///
        /// Honest to within one token: `LLMModel.prepare` prefills in chunks
        /// and ends with a synchronous `eval(cache)`, so the bulk of the work
        /// has genuinely landed before this returns. What is still in flight is
        /// the single `asyncEval`d step `TokenIterator.prepare` does at the
        /// end, and that lands in the generation timing instead. MLX's own
        /// `promptPrefillTime` draws the line in exactly the same place.
        let seconds: TimeInterval
    }

    /// Prepares a cache for a round.
    ///
    /// - Parameters:
    ///   - promptTokens: the full prompt for this round.
    ///   - owner: identity of the thread + model. A change invalidates.
    ///   - model: used to build a fresh cache and to prefill.
    ///   - parameters: generation parameters (cache shape depends on them).
    func prepare(
        promptTokens: [Int],
        owner: String,
        model: any LanguageModel,
        parameters: GenerateParameters
    ) throws -> Prepared {
        // `head` is the prompt minus the seed token — see the type's comment.
        let head = Array(promptTokens.dropLast())

        if ownerKey != owner { reset() }
        ownerKey = owner

        let reusable = baseline != nil && !tokens.isEmpty
            && head.count >= tokens.count
            && Array(head.prefix(tokens.count)) == tokens

        let base: [KVCache]
        let delta: [Int]
        if reusable, let existing = baseline {
            base = existing
            delta = Array(head.dropFirst(tokens.count))
        } else {
            base = model.newCache(parameters: parameters)
            delta = head
        }

        // Constructing a TokenIterator IS the prefill, so this extends the
        // baseline to hold exactly `head`. Its sampled token is discarded — one
        // wasted step against thousands of skipped ones.
        var seconds: TimeInterval = 0
        if !delta.isEmpty {
            let start = Date.timeIntervalSinceReferenceDate
            _ = try TokenIterator(
                input: LMInput(tokens: MLXArray(delta)),
                model: model, cache: base, parameters: parameters)
            seconds = Date.timeIntervalSinceReferenceDate - start
        }

        if head.count <= Self.maxCachedTokens {
            baseline = base
            tokens = head
        } else {
            // Too big to keep. This round still benefits from the prefill we
            // just did; the next one starts fresh.
            baseline = nil
            tokens = []
        }

        return Prepared(
            cache: base.map { $0.copy() }, prefilled: delta.count, seconds: seconds)
    }
}
