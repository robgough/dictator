import Foundation

/// Which of the two note-writing jobs a provider is doing.
///
/// The split exists because the two jobs have opposite cost profiles: the live
/// pass runs every ~30 s during a call and wants something cheap and local; the
/// final pass runs once over the whole transcript and is where note quality is
/// decided — the slot people point at a big cloud model if they have one.
enum ProviderSlot: String, Codable, CaseIterable, Sendable {
    case live
    case final

    var title: String {
        switch self {
        case .live:  return "Live notes use"
        case .final: return "Final notes use"
        }
    }

    var detail: String {
        switch self {
        case .live:
            return "The rough first pass written while the meeting records, every half minute or so. Keep this local unless you don't mind the traffic."
        case .final:
            return "The full pass after the meeting stops — notes, summary, speaker names, the coach report and the notes assistant. This is the one that decides note quality."
        }
    }
}

/// One configured note-writing backend. Persisted in `MeetingsSettings`
/// (synced), so it must never carry a secret: cloud keys live in the Keychain
/// under `keychainAccount`, which is just this config's id.
struct ProviderConfig: Codable, Equatable, Identifiable, Sendable {
    /// Stable UUID string, minted once when the provider is created. Doubles
    /// as the Keychain account name, so renaming a provider or editing its URL
    /// never orphans its key.
    var id: String
    var kind: Kind
    /// User-facing label ("Work OpenRouter", "Local model"). Free text.
    var name: String
    /// Only meaningful for `.openAICompatible`: which vendor's defaults to
    /// apply. `.custom` means "use `baseURL` as given".
    var preset: Preset?
    /// API root WITHOUT a trailing slash and WITHOUT `/chat/completions` —
    /// e.g. `https://api.openai.com/v1`. nil for a preset that supplies its
    /// own, and for the three local kinds.
    var baseURL: String?
    /// Cloud model id (`gpt-5`, `anthropic/claude-sonnet-5`, …) or, for
    /// `.localMLX`, the MLX checkpoint id. nil falls back to the kind's
    /// default (`MeetingsSettings.localLLMModelID` for local MLX,
    /// `AnthropicProvider.defaultModelID` for Anthropic).
    var modelID: String?

    init(id: String,
         kind: Kind,
         name: String,
         preset: Preset? = nil,
         baseURL: String? = nil,
         modelID: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.preset = preset
        self.baseURL = baseURL
        self.modelID = modelID
    }

    /// Keychain account for this provider's API key — nil for the local kinds,
    /// which have no secret. Always the config id, never the name.
    var keychainAccount: String? { kind.needsKey ? id : nil }

    /// The API root actually used at request time: the preset's, unless the
    /// user overrode it. nil when there's nothing sensible to use.
    var resolvedBaseURL: String? {
        if let baseURL, !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return baseURL.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        switch kind {
        case .openAICompatible:
            return preset?.defaultBaseURL
        case .anthropic:
            return AnthropicProvider.defaultBaseURL
        case .dictator, .localMLX, .apple:
            return nil
        }
    }

    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Borrow the model Dictator already has loaded, over the local Unix
        /// socket. Free (no second copy in RAM) but only available while
        /// Dictator is running with a model in memory.
        case dictator
        /// An MLX checkpoint loaded into this process.
        case localMLX
        /// Apple's on-device Foundation model.
        case apple
        /// Anything speaking OpenAI's `/chat/completions` — OpenAI itself,
        /// OpenRouter, a self-hosted vLLM/llama.cpp server.
        case openAICompatible
        /// Anthropic's Messages API.
        case anthropic

        /// Local kinds never send a transcript off the Mac.
        var isLocal: Bool {
            switch self {
            case .dictator, .localMLX, .apple: return true
            case .openAICompatible, .anthropic: return false
            }
        }

        /// Whether this kind authenticates with an API key stored in the
        /// Keychain. Exactly the not-local kinds today, but kept separate
        /// because a self-hosted OpenAI-compatible server may legitimately
        /// need no key (an empty Keychain item is fine).
        var needsKey: Bool { !isLocal }

        var displayName: String {
            switch self {
            case .dictator:         return "Dictator's model"
            case .localMLX:         return "Local model"
            case .apple:            return "Apple on-device"
            case .openAICompatible: return "OpenAI-compatible"
            case .anthropic:        return "Anthropic"
            }
        }

        var iconName: String {
            switch self {
            case .dictator:         return "link"
            case .localMLX:         return "cpu"
            case .apple:            return "apple.logo"
            case .openAICompatible: return "cloud"
            case .anthropic:        return "cloud"
            }
        }

        /// One line under the row explaining what this kind is, in plain
        /// language.
        var blurb: String {
            switch self {
            case .dictator:
                return "Uses the model Dictator already has in memory, over a local connection. Nothing leaves your Mac, and there's no second copy of the model. Needs Dictator running with sharing switched on."
            case .localMLX:
                return "Loads an MLX model into this app. Nothing leaves your Mac."
            case .apple:
                return "Uses Apple's on-device model. Nothing leaves your Mac. Today Apple only offers apps its small 4K-token model, which isn't big enough for a full meeting transcript."
            case .openAICompatible:
                return "Any service that speaks OpenAI's chat API — OpenAI, OpenRouter, or your own server."
            case .anthropic:
                return "Claude, direct from Anthropic."
            }
        }
    }

    enum Preset: String, Codable, CaseIterable, Sendable {
        case openAI
        case openRouter
        case custom

        var displayName: String {
            switch self {
            case .openAI:     return "OpenAI"
            case .openRouter: return "OpenRouter"
            case .custom:     return "Custom URL"
            }
        }

        var defaultBaseURL: String? {
            switch self {
            case .openAI:     return "https://api.openai.com/v1"
            case .openRouter: return "https://openrouter.ai/api/v1"
            case .custom:     return nil
            }
        }

        /// Suggested model id shown as the field's placeholder.
        var sampleModelID: String {
            switch self {
            case .openAI:     return "gpt-5"
            case .openRouter: return "anthropic/claude-sonnet-5"
            case .custom:     return "my-model"
            }
        }
    }

    /// Who the transcript is sent to, for the privacy line on the Providers
    /// tab. nil for the local kinds (nothing is sent anywhere).
    var vendorName: String? {
        switch kind {
        case .dictator, .localMLX, .apple:
            return nil
        case .anthropic:
            return "Anthropic"
        case .openAICompatible:
            switch preset {
            case .openAI?:     return "OpenAI"
            case .openRouter?: return "OpenRouter"
            default:
                guard let host = resolvedBaseURL.flatMap({ URL(string: $0)?.host }) else { return "this service" }
                return host
            }
        }
    }

    /// The sentence shown under any cloud provider on the Providers tab.
    var privacyLine: String? {
        guard let vendorName else { return nil }
        return "Transcripts for meetings using this provider are sent to \(vendorName)."
    }
}

/// Context window and per-request output cap for a cloud model.
///
/// Neither API reports its own limits, and getting the context window wrong is
/// expensive in both directions — too small and `MeetingSummaryService` shreds
/// a transcript that would have fitted in one pass, too large and the request
/// is rejected after the user has waited for a whole meeting to upload. So we
/// keep a small table of the models people actually configure and fall back
/// conservatively for anything else.
struct CloudModelLimits: Sendable, Equatable {
    var contextWindowTokens: Int
    var maxOutputTokens: Int

    /// What an unrecognised model id gets. 128K/8K is the floor of the current
    /// frontier crop and is safe to send to anything newer.
    static let fallback = CloudModelLimits(contextWindowTokens: 128_000, maxOutputTokens: 8_192)

    /// Keys are matched as case-insensitive *substrings* of the configured
    /// model id, longest key first — so `anthropic/claude-sonnet-5` (an
    /// OpenRouter id), `claude-sonnet-5-20260101` and a bare `claude-sonnet-5`
    /// all resolve to the same entry without an exhaustive list of dated
    /// snapshot ids.
    private static let table: [String: CloudModelLimits] = [
        // Anthropic
        "claude-opus-5":    .init(contextWindowTokens: 200_000, maxOutputTokens: 64_000),
        "claude-sonnet-5":  .init(contextWindowTokens: 200_000, maxOutputTokens: 64_000),
        "claude-haiku-5":   .init(contextWindowTokens: 200_000, maxOutputTokens: 64_000),
        "claude-opus-4":    .init(contextWindowTokens: 200_000, maxOutputTokens: 32_000),
        "claude-sonnet-4":  .init(contextWindowTokens: 200_000, maxOutputTokens: 64_000),
        "claude-haiku-4":   .init(contextWindowTokens: 200_000, maxOutputTokens: 32_000),
        "claude-3-5-haiku": .init(contextWindowTokens: 200_000, maxOutputTokens: 8_192),
        // OpenAI
        "gpt-5-mini": .init(contextWindowTokens: 400_000, maxOutputTokens: 128_000),
        "gpt-5-nano": .init(contextWindowTokens: 400_000, maxOutputTokens: 128_000),
        "gpt-5":      .init(contextWindowTokens: 400_000, maxOutputTokens: 128_000),
        "gpt-4.1":    .init(contextWindowTokens: 1_047_576, maxOutputTokens: 32_768),
        "gpt-4o":     .init(contextWindowTokens: 128_000, maxOutputTokens: 16_384),
        "o3":         .init(contextWindowTokens: 200_000, maxOutputTokens: 100_000),
        // Google, via OpenRouter
        "gemini-3":   .init(contextWindowTokens: 1_048_576, maxOutputTokens: 65_536),
        "gemini-2.5": .init(contextWindowTokens: 1_048_576, maxOutputTokens: 65_536),
        // Meta / Mistral / Qwen, via OpenRouter or a self-hosted server
        "llama-4":    .init(contextWindowTokens: 128_000, maxOutputTokens: 8_192),
        "mistral":    .init(contextWindowTokens: 128_000, maxOutputTokens: 8_192),
        "qwen3":      .init(contextWindowTokens: 128_000, maxOutputTokens: 16_384),
    ]

    static func forModel(_ modelID: String?) -> CloudModelLimits {
        guard let modelID, !modelID.isEmpty else { return fallback }
        let lower = modelID.lowercased()
        // Longest key first so "gpt-5-mini" doesn't match the "gpt-5" entry.
        for key in table.keys.sorted(by: { $0.count > $1.count }) where lower.contains(key) {
            return table[key]!
        }
        return fallback
    }
}
