import Foundation

/// Anything that speaks OpenAI's `POST {baseURL}/chat/completions`: OpenAI
/// itself, OpenRouter, or a self-hosted vLLM / llama.cpp / LM Studio server.
///
/// One implementation covers all three because the differences are two headers
/// and a base URL. The key comes from the Keychain on every request rather than
/// being held in memory: it means editing the key on the Providers tab takes
/// effect on the next pass with no cache to invalidate, and the secret never
/// sits in a long-lived object graph.
@MainActor
final class OpenAICompatibleProvider: MeetingLLM {
    let id: String
    let displayName: String
    var isLocal: Bool { false }

    private let preset: ProviderConfig.Preset
    private let baseURL: String?
    private let configuredModelID: String?

    /// Parameters this endpoint rejected, learned from its own 400s. See
    /// `adaptedBody`.
    private var usesMaxCompletionTokens = false
    private var omitsTemperature = false

    init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.name.isEmpty ? ProviderConfig.Kind.openAICompatible.displayName : config.name
        self.preset = config.preset ?? .custom
        self.baseURL = config.resolvedBaseURL
        self.configuredModelID = config.modelID?.trimmingCharacters(in: .whitespaces)
    }

    var modelID: String {
        guard let configuredModelID, !configuredModelID.isEmpty else { return preset.sampleModelID }
        return configuredModelID
    }

    private var limits: CloudModelLimits { CloudModelLimits.forModel(configuredModelID) }
    var contextWindowTokens: Int { limits.contextWindowTokens }
    var maxOutputTokens: Int { limits.maxOutputTokens }

    // MARK: - MeetingLLM

    /// Validation only — there's no connection to warm. Deliberately does NOT
    /// call the network: `prepare()` runs before every pass, and a health
    /// round-trip per pass would be both slow and billable.
    func prepare() async throws {
        _ = try endpoint(path: "chat/completions")
        _ = try apiKey()
        guard let configuredModelID, !configuredModelID.isEmpty else {
            throw MeetingLLMError.badConfiguration("\(displayName) has no model id set. Add one on the Providers tab.")
        }
    }

    func complete(system: String,
                  user: String,
                  maxTokens: Int,
                  temperature: Double,
                  cancellation: @Sendable @escaping () -> Bool) async throws -> String {
        try await prepare()
        let url = try endpoint(path: "chat/completions")
        let key = try apiKey()

        // Up to two adaptation passes: an endpoint that rejects `max_tokens`
        // (the newer OpenAI models) or a fixed-temperature reasoning model
        // answers 400 with the offending parameter named, and we retry once
        // having learned it. Everything else surfaces as-is.
        for _ in 0..<3 {
            let body = requestBody(system: system, user: user, maxTokens: maxTokens, temperature: temperature)
            let request = try makeRequest(url: url, key: key, body: body)
            let response = try await CloudHTTP.sendWithRetry(
                request,
                providerName: displayName,
                cancellation: cancellation
            )
            if response.isSuccess {
                return try parseCompletion(response.data)
            }
            if response.status == 400, adapt(to: response.errorMessage) { continue }
            throw httpError(response)
        }
        throw MeetingLLMError.transport("\(displayName) rejected every form of the request.")
    }

    /// `GET {baseURL}/models` is the cheapest proof that the URL and key are
    /// both right. Plenty of self-hosted servers don't implement it, so a 404 /
    /// 405 falls through to a one-token completion, which proves rather more.
    func healthCheck() async throws -> String {
        try await prepare()
        let key = try apiKey()
        let modelsURL = try endpoint(path: "models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        applyHeaders(to: &request, key: key)

        let response = try await CloudHTTP.send(request, cancellation: { false })
        if response.isSuccess {
            if let ids = Self.modelIDs(in: response.data) {
                guard ids.contains(modelID) else {
                    throw MeetingLLMError.badConfiguration(
                        "\(displayName) is reachable, but it doesn't list \"\(modelID)\". Check the model id on the Providers tab."
                    )
                }
            }
            return modelID
        }
        if response.status == 404 || response.status == 405 || response.status == 501 {
            // No /models endpoint. Prove the round trip instead.
            _ = try await complete(
                system: "Reply with the single word OK. Nothing else.",
                user: "OK",
                maxTokens: 1,
                temperature: 0,
                cancellation: { false }
            )
            return modelID
        }
        throw httpError(response)
    }

    // MARK: - Request building

    private func endpoint(path: String) throws -> URL {
        guard let baseURL, !baseURL.isEmpty else {
            throw MeetingLLMError.badConfiguration("\(displayName) has no server URL set. Add one on the Providers tab.")
        }
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
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if preset == .openRouter {
            // OpenRouter attributes requests to an app through these two and
            // shows them on the user's activity page. Both are documented as
            // optional but they're what makes a key's usage legible.
            request.setValue("https://dictator.robgough.net", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Dictator Meetings", forHTTPHeaderField: "X-Title")
        }
    }

    private func makeRequest(url: URL, key: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, key: key)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw MeetingLLMError.transport("Couldn't encode the request: \(error.localizedDescription)")
        }
        return request
    }

    private func requestBody(system: String, user: String, maxTokens: Int, temperature: Double) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let cap = max(1, min(maxTokens, maxOutputTokens))
        body[usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = cap
        if !omitsTemperature { body["temperature"] = temperature }
        return body
    }

    /// Learns from a 400. Returns true when something changed and the request
    /// is worth resending.
    ///
    /// Both of these are real, current failures rather than defensive
    /// speculation: OpenAI's newer models 400 on `max_tokens` ("Use
    /// 'max_completion_tokens' instead"), and its reasoning models 400 on any
    /// `temperature` but the default.
    private func adapt(to message: String) -> Bool {
        let lower = message.lowercased()
        if !usesMaxCompletionTokens, lower.contains("max_completion_tokens") {
            usesMaxCompletionTokens = true
            NSLog("[DictatorMeetings] \(displayName): switching to max_completion_tokens")
            return true
        }
        if !omitsTemperature, lower.contains("temperature") {
            omitsTemperature = true
            NSLog("[DictatorMeetings] \(displayName): dropping temperature (model only supports its default)")
            return true
        }
        return false
    }

    // MARK: - Response parsing

    private func parseCompletion(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingLLMError.transport("\(displayName) returned something that isn't JSON.")
        }
        if let usage = object["usage"] as? [String: Any] {
            let promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
            let completionTokens = (usage["completion_tokens"] as? Int) ?? 0
            UsageStatsStore.shared.recordLLMTokens(in: promptTokens, out: completionTokens)
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw MeetingLLMError.emptyResponse(displayName)
        }
        // `content` is normally a string; some gateways return the parts array
        // the vision APIs use, so handle both rather than failing on a shape
        // that carries perfectly good text.
        let content: String
        if let message = first["message"] as? [String: Any] {
            if let text = message["content"] as? String {
                content = text
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined()
            } else {
                content = ""
            }
        } else if let text = first["text"] as? String {
            content = text
        } else {
            content = ""
        }
        let cleaned = LLMTextUtilities.clean(content)
        guard !cleaned.isEmpty else {
            if let reason = first["finish_reason"] as? String, reason == "length" {
                throw MeetingLLMError.emptyResponse("\(displayName) (hit the reply length cap before writing anything)")
            }
            throw MeetingLLMError.emptyResponse(displayName)
        }
        return cleaned
    }

    /// Model ids from a `/models` listing, or nil when the body isn't the
    /// shape we know (in which case we don't second-guess the user's model id).
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
            return .badConfiguration("\(displayName): the server URL or model id looks wrong (HTTP 404). \(response.errorMessage)")
        default:
            return .http(status: response.status, message: response.errorMessage)
        }
    }
}
