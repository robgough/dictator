import Foundation
import FoundationModels

/// Picks which Apple model runs a pass: Private Cloud Compute when the user
/// allows it and it's reachable, otherwise the on-device model.
///
/// Both the filler cleanup and Assist go through `respond`, so the choice —
/// and the fallback — live in one place. PCC is a far larger model (32K
/// context, reasoning) and noticeably better at both passes, but it's a
/// network round trip with a quota, so any PCC failure (offline, quota
/// reached, service down) quietly reruns the request on device rather than
/// failing the dictation.
///
/// **Two gates, both needed.** `PrivateCloudComputeLanguageModel` exists only
/// in the iOS 27 SDK and needs the managed entitlement
/// `com.apple.developer.private-cloud-compute`, which Apple grants on
/// request. Asking for an entitlement the provisioning profile doesn't carry
/// breaks signing, so the code is compiled only when `PRIVATE_CLOUD_COMPUTE`
/// is defined — see the iOS target in project.yml for turning both on once
/// the request is approved. Until then this is the on-device model, exactly
/// as before.
@MainActor
enum AppleIntelligenceModel {
    /// True when this build can use PCC at all (flag compiled in, iOS 27).
    /// Settings shows the toggle only then.
    static var cloudSupported: Bool {
        #if PRIVATE_CLOUD_COMPUTE
        if #available(iOS 27, *) { return true }
        #endif
        return false
    }

    /// The user's choice, on by default.
    static var cloudEnabled: Bool {
        UserDefaults.standard.bool(forKey: DictatorIOSSettings.privateCloudComputeKey)
    }

    /// Why PCC isn't being used right now, for Settings; nil when it is.
    static var cloudUnavailableReason: String? {
        #if PRIVATE_CLOUD_COMPUTE
        if #available(iOS 27, *) {
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                if PrivateCloudComputeLanguageModel().quotaUsage.isLimitReached {
                    return "You've reached Apple's Private Cloud Compute limit for now, so Dictator is using the on-device model."
                }
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device can't use Private Cloud Compute."
            case .unavailable:
                return "Private Cloud Compute isn't ready yet. Dictator uses the on-device model until it is."
            }
        }
        #endif
        return "Needs iOS 27."
    }

    /// Run one prompt and return the model's text, with which model ran it.
    static func respond(
        instructions: String,
        prompt: String,
        options: GenerationOptions
    ) async throws -> (content: String, usedCloud: Bool) {
        #if PRIVATE_CLOUD_COMPUTE
        if #available(iOS 27, *), cloudEnabled {
            let cloud = PrivateCloudComputeLanguageModel()
            if cloud.isAvailable, !cloud.quotaUsage.isLimitReached {
                do {
                    let session = LanguageModelSession(model: cloud, instructions: Instructions(instructions))
                    let response = try await session.respond(to: prompt, options: options)
                    return (response.content, true)
                } catch let error as PrivateCloudComputeLanguageModel.Error {
                    NSLog("[DictatorIOS] Private Cloud Compute failed, using on-device: \(error.localizedDescription)")
                }
            }
        }
        #endif
        // Everything here rewrites text the user gave us, which is what this
        // guardrail mode is for. The default is tuned for open-ended chat
        // and refuses ordinary dictation that sounds sensitive.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: Instructions(instructions))
        let response = try await session.respond(to: prompt, options: options)
        return (response.content, false)
    }
}
