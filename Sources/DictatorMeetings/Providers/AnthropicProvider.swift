import Foundation

/// Claude, direct from Anthropic's Messages API.
///
/// Separate from `OpenAICompatibleProvider` because the wire shape genuinely
/// differs: the system prompt is a top-level field rather than a message,
/// `max_tokens` is REQUIRED (there's no "as much as you like" default), the
/// key travels in `x-api-key` rather than a bearer token, and the reply is an
/// array of content blocks. Someone who wants Claude through OpenRouter uses
/// the OpenAI-compatible provider instead; this is the direct path.
@MainActor
final class AnthropicProvider: MeetingLLM {
    /// API root. Overridable through `ProviderConfig.baseURL` for a proxy or a
    /// gateway that re-hosts the Messages API.
    nonisolated static let defaultBaseURL = "https://api.anthropic.com"

    /// The version header Anthropic requires on every request. Pinned: it's a
    /// dated API contract, not a "latest" channel, and bumping it is a
    /// deliberate act.
    nonisolated static let apiVersion = "2023-06-01"

    /// The current Sonnet — the right default for meeting notes: 200K of
    /// context takes an entire meeting in one pass, and it's the quality tier
    /// people reach for cloud providers to get.
    nonisolated static let defaultModelID = "claude-sonnet-5"

    /// Sonnet will emit up to 64K tokens, but a set of meeting notes is a few
    /// thousand at most. Capping requests at 16K keeps a mis-steered model
    /// from generating (and billing for) an essay, while leaving plenty of
    /// headroom over the longest notes we've seen.
    nonisolated static let requestOutputCap = 16_384

    let id: String
    let displayName: String
    var isLocal: Bool { false }

    private let baseURL: String
    private let configuredModelID: String?

    init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.name.isEmpty ? ProviderConfig.Kind.anthropic.displayName : config.name
        self.baseURL = config.resolvedBaseURL ?? Self.defaultBaseURL
        self.configuredModelID = config.modelID?.trimmingCharacters(in: .whitespaces)
    }

    var modelID: String {
        guard let configuredModelID, !configuredModelID.isEmpty else { return Self.defaultModelID }
        return configuredModelID
    }

    private var limits: CloudModelLimits {
        CloudModelLimits.forModel(configuredModelID?.isEmpty == false ? configuredModelID : Self.defaultModelID)
    }

    var contextWindowTokens: Int { limits.contextWindowTokens }

    /// What we'll ever ask for in one request — the model's own ceiling,
    /// clamped by `requestOutputCap`.
    var maxOutputTokens: Int { min(limits.maxOutputTokens, Self.requestOutputCap) }

    // MARK: - MeetingLLM

    /// Config validation only; no network call. `complete` runs many times per
    /// meeting and a health round-trip per pass would be slow and billable.
    func prepare() async throws {
        _ = try endpoint(path: "v1/messages")
        _ = try apiKey()
    }

    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String {
        try await prepare()
        let url = try endpoint(path: "v1/messages")
        let key = try apiKey()

        var body: [String: Any] = [
            "model": modelID,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
            // Required by the API — there is no default.
            "max_tokens": max(1, min(maxTokens, maxOutputTokens)),
        ]
        // Anthropic accepts 0...1; the meetings passes only ever use 0 or 0.2,
        // but clamp anyway so a future caller can't send something rejected.
        body["temperature"] = min(1.0, max(0.0, temperature))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, key: key)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw MeetingLLMError.transport("Couldn't encode the request: \(error.localizedDescription)")
        }

        let response = try await CloudHTTP.sendWithRetry(
            request,
            providerName: displayName,
            cancellation: cancellation
        )
        guard response.isSuccess else { throw httpError(response) }
        return try parseMessage(response.data)
    }

    /// `GET /v1/models` — cheap, authenticated, and it tells us whether the
    /// configured model id actually exists on this account.
    func healthCheck() async throws -> String {
        try await prepare()
        let key = try apiKey()
        var request = URLRequest(url: try endpoint(path: "v1/models"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, key: key)

        let response = try await CloudHTTP.send(request, cancellation: { false })
        if response.isSuccess {
            if let ids = Self.modelIDs(in: response.data), !ids.contains(modelID) {
                // Anthropic lists dated snapshot ids (`claude-sonnet-5-…`)
                // alongside the aliases, so accept a prefix match too.
                let matchesSnapshot = ids.contains { $0.hasPrefix(modelID) }
                guard matchesSnapshot else {
                    throw MeetingLLMError.badConfiguration(
                        "Anthropic doesn't list a model called \"\(modelID)\" for this key. Check the model id on the Providers tab."
                    )
                }
            }
            return modelID
        }
        if response.status == 404 || response.status == 405 {
            // A proxy that doesn't re-host /v1/models. Prove the round trip.
            _ = try await complete(
                system: "Reply with the single word OK. Nothing else.",
                user: "OK",
                maxTokens: 8,
                temperature: 0,
                cancellation: { false }
            )
            return modelID
        }
        throw httpError(response)
    }

    // MARK: - Internals

    private func endpoint(path: String) throws -> URL {
        guard let url = URL(string: baseURL + "/" + path) else {
            throw MeetingLLMError.badConfiguration("\(displayName)'s server URL isn't a valid address: \(baseURL)")
        }
        return url
    }

    private func apiKey() throws -> String {
        guard let key = KeychainStore.get(account: id), !key.isEmpty else {
            throw MeetingLLMError.missingKey(displayName)
        }
        return key
    }

    private func applyHeaders(to request: inout URLRequest, key: String) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func parseMessage(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingLLMError.transport("\(displayName) returned something that isn't JSON.")
        }
        if let usage = object["usage"] as? [String: Any] {
            let inTokens = (usage["input_tokens"] as? Int) ?? 0
            let outTokens = (usage["output_tokens"] as? Int) ?? 0
            UsageStatsStore.shared.recordLLMTokens(in: inTokens, out: outTokens)
        }
        guard let blocks = object["content"] as? [[String: Any]] else {
            throw MeetingLLMError.emptyResponse(displayName)
        }
        // Concatenate every text block rather than taking `content[0].text`:
        // a reply can legitimately arrive as several blocks, and dropping all
        // but the first would silently truncate the notes.
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let cleaned = LLMTextUtilities.clean(text)
        guard !cleaned.isEmpty else {
            if let reason = object["stop_reason"] as? String, reason == "max_tokens" {
                throw MeetingLLMError.emptyResponse("\(displayName) (hit the reply length cap before writing anything)")
            }
            throw MeetingLLMError.emptyResponse(displayName)
        }
        return cleaned
    }

    private static func modelIDs(in data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]]
        else { return nil }
        let ids = list.compactMap { $0["id"] as? String }
        return ids.isEmpty ? nil : Set(ids)
    }

    private func httpError(_ response: CloudHTTP.Response) -> MeetingLLMError {
        switch response.status {
        case 401, 403:
            return .missingKey(displayName)
        case 404:
            return .badConfiguration("\(displayName): the model id or server URL looks wrong (HTTP 404). \(response.errorMessage)")
        default:
            return .http(status: response.status, message: response.errorMessage)
        }
    }
}
