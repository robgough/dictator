import SwiftUI

/// The models an OpenAI-compatible service offers, from its `/models` list —
/// so the model id can be picked rather than typed, which is where most
/// provider set-ups went wrong. OpenRouter lists its whole catalogue without
/// a key, with names, context lengths and prices; OpenAI and self-hosted
/// servers answer the same request with the key and just ids.
struct RemoteModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let contextLength: Int?
    /// Dollars per million tokens, when the service says.
    let promptPrice: Double?
    let completionPrice: Double?
}

enum RemoteModelList {
    enum Failure: LocalizedError {
        case noServer, badResponse(Int), unreadable
        var errorDescription: String? {
            switch self {
            case .noServer: return "Set the server URL first."
            case .badResponse(let code):
                return code == 401 ? "The service wants an API key to list its models." : "The service answered with an error (\(code))."
            case .unreadable: return "The service's model list wasn't in a form this understands."
            }
        }
    }

    static func fetch(baseURL: String?, apiKey: String?) async throws -> [RemoteModel] {
        guard let baseURL, let url = URL(string: baseURL + "/models") else { throw Failure.noServer }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badResponse(http.statusCode)
        }
        guard let list = try? JSONDecoder().decode(ListResponse.self, from: data) else { throw Failure.unreadable }
        return list.data
            .map { entry in
                RemoteModel(
                    id: entry.id,
                    name: entry.name ?? entry.id,
                    contextLength: entry.context_length,
                    promptPrice: entry.pricing?.prompt.flatMap(Double.init).map { $0 * 1_000_000 },
                    completionPrice: entry.pricing?.completion.flatMap(Double.init).map { $0 * 1_000_000 })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private struct ListResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable {
            let id: String
            let name: String?
            let context_length: Int?
            let pricing: Pricing?
        }
        struct Pricing: Decodable {
            let prompt: String?
            let completion: String?
        }
    }
}

/// A searchable list of a service's models, shown from the provider editor's
/// "Choose…" button.
struct RemoteModelPicker: View {
    let baseURL: String?
    let apiKey: String?
    let selection: String
    let onPick: (String) -> Void

    @State private var models: [RemoteModel] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)
            Group {
                if loading {
                    ProgressView("Fetching models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { model in
                        Button { onPick(model.id) } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.name).fontWeight(model.id == selection ? .semibold : .regular)
                                    Text(model.id).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let context = model.contextLength {
                                        Text("\(Self.tokens(context)) context").font(.caption)
                                    }
                                    if let price = priceText(model) {
                                        Text(price).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if model.id == selection {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            Text("\(filtered.count) of \(models.count) models")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 460, height: 420)
        .task {
            do {
                models = try await RemoteModelList.fetch(baseURL: baseURL, apiKey: apiKey)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private var filtered: [RemoteModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private func priceText(_ m: RemoteModel) -> String? {
        guard let p = m.promptPrice, let c = m.completionPrice else { return nil }
        if p == 0 && c == 0 { return "Free" }
        return String(format: "$%.2f / $%.2f per M", p, c)
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : "\(n / 1000)K"
    }
}
