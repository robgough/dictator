import AppKit
import Foundation
import Observation

/// Result of the last "Test" on a provider, for the status dot on the
/// Providers tab.
enum ProviderStatus: Equatable, Sendable {
    /// Never tested this session.
    case unknown
    case checking
    /// Answered, and this is the model id that answered.
    case ok(String)
    case failed(String)
}

/// Builds and caches the live `MeetingLLM` instances from
/// `MeetingsSettings.providers`, and owns the "which one actually runs this
/// pass?" decision.
///
/// This replaces `MeetingsFeature` from the single-app era: the requirement
/// gate is no longer "is a specific model selected in Dictator's settings" but
/// "does the final slot resolve to something that can answer", which is a
/// question only this type can answer.
///
/// Instances are cached because they hold real state — the socket provider's
/// cached `status`, the OpenAI provider's learned parameter quirks, the local
/// provider's model id — and because rebuilding `LocalMLXProvider` on every
/// pass would be a needless churn around a loaded container.
@MainActor
@Observable
final class ProviderRegistry {
    static let shared = ProviderRegistry()

    /// Keyed by `ProviderConfig.id`.
    @ObservationIgnored private var cache: [String: any MeetingLLM] = [:]
    /// The config each cached instance was built from, so `refresh` can tell a
    /// cosmetic rename from a change that needs a rebuild.
    @ObservationIgnored private var builtFrom: [String: ProviderConfig] = [:]

    /// Last test result per provider id. Observable so the Providers tab's
    /// dots update without polling.
    private(set) var statuses: [String: ProviderStatus] = [:]

    /// Bumped whenever the resolution inputs change (settings saved, Dictator
    /// launched or quit). Views read it so `provider(for:)`-derived copy —
    /// which reads non-observable state like the socket file's existence —
    /// re-renders.
    private(set) var generation: Int = 0

    private init() {
        observeDictatorLifecycle()
    }

    private var settings: MeetingsSettings { MeetingsAppState.shared.settings }

    /// Bundle identifier of the dictation app whose loaded model we borrow.
    /// `nonisolated` so the workspace-notification closure can read it without
    /// hopping to the main actor just to compare two strings.
    nonisolated static let dictatorBundleID = "net.robgough.Dictator"

    /// `provider(for:)` and `requirementMessage` branch on whether Dictator is
    /// running, which is not observable state — nothing tells SwiftUI to
    /// re-read it when the user quits Dictator mid-meeting, so the Providers
    /// tab would keep claiming a shared model that's gone (and the recording
    /// UI would keep offering a CTA that now falls back silently).
    ///
    /// `NSWorkspace`'s launch/terminate notifications are the cheap fix: filter
    /// to Dictator's bundle id and bump `generation`, which every derived view
    /// reads. Note these arrive on `NSWorkspace.shared.notificationCenter`, NOT
    /// the default centre — posting to the default centre is a classic silent
    /// no-op here.
    private func observeDictatorLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            // The returned token is deliberately dropped: this is a
            // process-lifetime singleton, so there is never a moment to
            // unregister, and holding the tokens would only add a
            // non-Sendable stored property for a `deinit` that can't run.
            _ = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == ProviderRegistry.dictatorBundleID else { return }
                MainActor.assumeIsolated {
                    NSLog("[DictatorMeetings] Dictator \(name == NSWorkspace.didLaunchApplicationNotification ? "launched" : "quit") — re-resolving providers.")
                    ProviderRegistry.shared.refresh()
                }
            }
        }
    }

    // MARK: - Cache

    /// Reconciles the cache with the current settings: drops instances whose
    /// provider was deleted or materially changed, re-points a local MLX
    /// provider whose model id moved (cheaper than a rebuild — a warm
    /// container survives), and bumps `generation` so the UI re-reads.
    ///
    /// Safe and cheap to call on every save.
    func refresh() {
        let configs = settings.providers
        let live = Set(configs.map(\.id))
        for id in cache.keys where !live.contains(id) {
            cache.removeValue(forKey: id)
            builtFrom.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
        }
        for config in configs {
            guard let previous = builtFrom[config.id] else { continue }
            if previous == config { continue }
            if config.kind == .localMLX,
               previous.kind == .localMLX,
               let local = cache[config.id] as? LocalMLXProvider {
                local.update(modelID: config.modelID?.isEmpty == false ? config.modelID! : settings.localLLMModelID)
                builtFrom[config.id] = config
                continue
            }
            cache.removeValue(forKey: config.id)
            builtFrom.removeValue(forKey: config.id)
            statuses[config.id] = .unknown
        }
        generation &+= 1
    }

    /// The live instance for a config, building it on first use.
    func instance(for config: ProviderConfig) -> any MeetingLLM {
        if let cached = cache[config.id], builtFrom[config.id] == config { return cached }
        let built: any MeetingLLM
        switch config.kind {
        case .dictator:
            built = DictatorSocketProvider(config: config)
        case .localMLX:
            built = LocalMLXProvider(config: config, fallbackModelID: settings.localLLMModelID)
        case .apple:
            built = AppleFoundationProvider(config: config)
        case .openAICompatible:
            built = OpenAICompatibleProvider(config: config)
        case .anthropic:
            built = AnthropicProvider(config: config)
        }
        cache[config.id] = built
        builtFrom[config.id] = config
        return built
    }

    // MARK: - Resolution

    /// The provider that should run a pass for `slot`, applying the fallback
    /// rule: a slot pointing at Dictator's shared model when Dictator isn't
    /// available drops to the local MLX model (only when it's actually
    /// downloaded — we never start a multi-gigabyte download because a meeting
    /// ended), then to Apple's on-device model, then nil.
    ///
    /// Cloud providers are returned as configured: reachability can't be
    /// established without a billable round trip, so a broken key surfaces as
    /// a clear error from the pass rather than a silent downgrade to a
    /// different (possibly worse, possibly not what the user wanted) model.
    func provider(for slot: ProviderSlot) -> (any MeetingLLM)? {
        guard let config = settings.providerConfig(for: slot) else { return localFallback() }
        if config.kind == .dictator, !DictatorSocketProvider.isAvailable {
            return localFallback()
        }
        return instance(for: config)
    }

    /// Which config `provider(for:)` will actually use — same rules, but
    /// returns the config so the UI can say "falling back to Local model".
    func resolvedConfig(for slot: ProviderSlot) -> ProviderConfig? {
        guard let config = settings.providerConfig(for: slot) else { return localFallbackConfig() }
        if config.kind == .dictator, !DictatorSocketProvider.isAvailable {
            return localFallbackConfig()
        }
        return config
    }

    /// True when the slot's configured provider isn't the one that would run.
    func isFallingBack(for slot: ProviderSlot) -> Bool {
        guard let configured = settings.providerConfig(for: slot) else { return true }
        return resolvedConfig(for: slot)?.id != configured.id
    }

    private func localFallbackConfig() -> ProviderConfig? {
        if let mlx = settings.providers.first(where: { $0.kind == .localMLX }) {
            let provider = instance(for: mlx)
            if let local = provider as? LocalMLXProvider, local.isDownloaded { return mlx }
        }
        if let apple = settings.providers.first(where: { $0.kind == .apple }),
           AppleFoundationAvailability.isUsable {
            return apple
        }
        return nil
    }

    private func localFallback() -> (any MeetingLLM)? {
        guard let config = localFallbackConfig() else { return nil }
        return instance(for: config)
    }

    // MARK: - Gates

    /// nil when the final-notes slot resolves to something that can write
    /// notes; otherwise one sentence saying what to fix. Meetings still
    /// *record* without a provider — you get audio and a transcript — so this
    /// gates the notes CTA, not the recorder.
    ///
    /// Replaces `MeetingsFeature.llmRequirementMessage`.
    var requirementMessage: String? {
        guard let config = settings.providerConfig(for: .final) else {
            return "Pick a model for the final notes on the Providers tab."
        }
        if config.kind == .dictator, !DictatorSocketProvider.isAvailable {
            guard localFallbackConfig() != nil else {
                return "Dictator isn't running, so there's no shared model to borrow — and there's no local model downloaded to fall back on. Open Dictator, download a model on the Models tab, or add a cloud provider."
            }
            return nil
        }
        switch config.kind {
        case .dictator:
            return nil
        case .localMLX:
            guard let local = instance(for: config) as? LocalMLXProvider else { return nil }
            guard local.isDownloaded else {
                let name = local.catalogEntry?.displayName ?? local.modelID
                return "\(name) isn't downloaded yet — get it on the Models tab, or point the final notes at another provider."
            }
            return nil
        case .apple:
            guard AppleFoundationAvailability.isUsable else {
                return AppleFoundationAvailability.unavailableMessage
                    ?? "Apple's on-device model isn't available on this Mac. Pick another provider for the final notes."
            }
            return nil
        case .openAICompatible, .anthropic:
            guard let account = config.keychainAccount, KeychainStore.has(account: account) else {
                return "\(config.name) has no API key saved. Add one on the Providers tab."
            }
            return nil
        }
    }

    /// Non-blocking caution when the final slot resolves but the model behind
    /// it writes notes we wouldn't vouch for. Shown alongside the feature,
    /// never instead of it.
    ///
    /// Replaces `MeetingsFeature.llmQualityNote`.
    var qualityNote: String? {
        guard requirementMessage == nil else { return nil }
        guard let config = resolvedConfig(for: .final) else { return nil }
        let recommended = ModelCatalog.meetingsRecommendedLLMName
        switch config.kind {
        case .dictator:
            guard let socket = instance(for: config) as? DictatorSocketProvider else { return nil }
            // nil = we haven't asked Dictator yet; don't nag on a guess.
            guard socket.remoteIsMeetingsCapable == false else { return nil }
            return "Dictator is sharing a model that's on the small side for meeting notes. Quality may drop on long meetings — attribution slips or invented structure. Switch Dictator to \(recommended), or point the final notes at another provider."
        case .localMLX:
            guard let local = instance(for: config) as? LocalMLXProvider, !local.isMeetingsCapable else { return nil }
            let name = local.catalogEntry?.displayName ?? local.modelID
            return "Meeting notes are tuned for \(recommended). \(name) will still write them, but quality may drop on long meetings — attribution slips or invented structure."
        case .apple:
            guard !AppleFoundationAvailability.isMeetingsCapable else { return nil }
            return "Apple only offers apps its small on-device model (a \(AppleFoundationAvailability.contextSize ?? 4_096)-token window), which isn't enough room for a full meeting transcript. Expect the notes to drift. \(recommended) or a cloud provider will do noticeably better."
        case .openAICompatible, .anthropic:
            return nil
        }
    }

    /// Whether any pass will send a transcript off this Mac, for the copy on
    /// the Providers tab and the meeting detail view.
    var usesCloudProvider: Bool {
        ProviderSlot.allCases.contains { resolvedConfig(for: $0)?.kind.isLocal == false }
    }

    // MARK: - Health checks

    func status(for id: String) -> ProviderStatus { statuses[id] ?? .unknown }

    /// Runs the provider's health check and records the result. Never throws —
    /// the outcome IS the status.
    func test(_ config: ProviderConfig) async {
        statuses[config.id] = .checking
        let provider = instance(for: config)
        do {
            let model = try await provider.healthCheck()
            statuses[config.id] = .ok(model)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statuses[config.id] = .failed(message)
        }
    }
}
