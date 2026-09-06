import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// Bridges swift-transformers into mlx-swift-lm 3.x, which decoupled from it.
///
/// 3.x's official glue is the `#hubDownloader` / `#huggingFaceTokenizerLoader`
/// macro pair in the MLXHuggingFace product, but those target the new
/// `HubClient`, whose cache uses the content-addressed
/// `models--<org>--<name>/snapshots/<commit>/` layout. Existing installs have
/// multi-GB weights in the legacy `HubApi(downloadBase:)` layout —
/// `<llmRoot>/models/<org>/<name>/` with `.cache/huggingface/download`
/// metadata inside — and ModelManager's download/resume/delete logic reads
/// that layout directly. Hand-writing the two small bridges against the
/// legacy `HubApi` (still shipped in swift-transformers 1.3.x) keeps the
/// on-disk story byte-identical and skips the macro target's swift-syntax
/// build + Xcode macro-trust prompt.

/// `Downloader` conformance backed by `HubApi(downloadBase:)`.
struct HubDownloader: Downloader {
    let downloadBase: URL

    /// Mirrors mlx-swift-lm's `modelDownloadPatterns` (package-internal there):
    /// weights + tokenizer/config JSON + chat templates.
    static let modelFilePatterns = ["*.safetensors", "*.json", "*.jinja"]

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // `useLatest` is ignored, matching the upstream HubClient bridge:
        // snapshot() always revalidates the file list against the server and
        // resumes/skips per-file based on local etag metadata.
        let hub = HubApi(downloadBase: downloadBase)
        return try await hub.snapshot(
            from: HubApi.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// `TokenizerLoader` conformance backed by `Tokenizers.AutoTokenizer`.
struct HubTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Adapts swift-transformers' `Tokenizers.Tokenizer` to MLXLMCommon's
/// decoupled `Tokenizer` protocol. Mirrors the expansion of the
/// `#adaptHuggingFaceTokenizer` macro.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` instead of `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
