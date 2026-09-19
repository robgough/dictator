import Foundation

/// Exa's search API.
///
/// The paid-and-better option, for people who'd rather have good results than
/// no account. Unlike the DuckDuckGo backend this needs no browser engine —
/// it's an ordinary JSON POST — but it does need a key, and the query is tied
/// to the user's Exa account and billed to it. The Settings disclosure says so
/// in those words.
///
/// Asks for **highlights**, not page text. `contents: { text: true }` returns
/// whole pages, which is both far more money and far more context than a
/// result list has any business spending — the model opens the one it wants
/// with `fetch_url`, exactly as it does on the other backend. Keeping the two
/// backends' output shape identical is deliberate: the model must not be able
/// to tell which one answered.
enum ExaSearch {
    private static let endpoint = URL(string: "https://api.exa.ai/search")!
    private static let timeout: TimeInterval = 20

    enum ExaError: LocalizedError {
        case noKey
        case unauthorised
        case outOfCredits
        case rateLimited
        case http(Int, String?)
        case malformed

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No Exa API key is saved. Add one in Settings → Chat, or switch the "
                    + "search service to DuckDuckGo, which needs no key."
            case .unauthorised:
                return "Exa rejected the API key. Check it in Settings → Chat."
            case .outOfCredits:
                return "The Exa account is out of credits."
            case .rateLimited:
                return "Exa is rate-limiting these searches. Try again shortly."
            case .http(let status, let detail):
                if let detail, !detail.isEmpty { return "Exa returned HTTP \(status): \(detail)" }
                return "Exa returned HTTP \(status)."
            case .malformed:
                return "Exa's reply wasn't in the expected format."
            }
        }
    }

    static func search(_ query: String, limit: Int) async throws -> [WebSearchResult] {
        guard let key = SearchSecrets.value(for: .exa), !key.isEmpty else {
            throw ExaError.noKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        let body: [String: Any] = [
            "query": query,
            "numResults": limit,
            // Let Exa choose between its keyword and neural paths. A chat
            // question can be either a name to look up or a description of
            // something, and the model gives no signal which.
            "type": "auto",
            "contents": [
                "highlights": ["maxCharacters": WebSearcher.maximumSnippetCharacters]
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            switch http.statusCode {
            case 401, 403: throw ExaError.unauthorised
            case 402: throw ExaError.outOfCredits
            case 429: throw ExaError.rateLimited
            default: throw ExaError.http(http.statusCode, errorDetail(from: data))
            }
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = payload["results"] as? [[String: Any]]
        else { throw ExaError.malformed }

        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return WebSearchResult(
                title: (row["title"] as? String) ?? url,
                url: url,
                snippet: snippet(from: row)
            )
        }
    }

    /// Prefers the query-guided highlights, then a summary, then the head of
    /// the page text — whichever the response actually carries.
    private static func snippet(from row: [String: Any]) -> String {
        if let highlights = row["highlights"] as? [String] {
            let joined = highlights
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
            if !joined.isEmpty { return joined }
        }
        if let summary = row["summary"] as? String, !summary.isEmpty { return summary }
        if let text = row["text"] as? String, !text.isEmpty { return text }
        return ""
    }

    private static func errorDetail(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["error"] as? String)
            ?? (object["message"] as? String)
            ?? ((object["error"] as? [String: Any])?["message"] as? String)
    }
}
