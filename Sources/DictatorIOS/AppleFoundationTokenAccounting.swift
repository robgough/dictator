import Foundation

/// Best-effort LLM token accounting for the iOS Apple Foundation
/// Models call sites (`AppleFoundationCleanup`, `AppleFoundationAssist`).
///
/// Why a heuristic and not the framework's own `tokenCount(for:)`:
/// the exact API is only available on macOS / iOS **26.4+**, and the
/// app's deployment target is 26.0. We fall back to the industry-
/// standard 4-chars-per-token approximation for English BPE
/// tokenisers — accurate to within ~10–15% for typical dictation
/// prompts and replies, which is well inside the "fun stat on the
/// About screen" tolerance. When the deployment target moves to 26.4
/// we can swap the implementation for the exact call without
/// touching the call sites.
enum AppleFoundationTokenAccounting {
    @MainActor
    static func record(promptCharCount: Int, responseCharCount: Int) {
        let approxIn = max(0, promptCharCount) / 4
        let approxOut = max(0, responseCharCount) / 4
        UsageStatsStore.shared.recordLLMTokens(in: approxIn, out: approxOut)
    }
}
