import Foundation
import Security

/// API keys for the search backends, in the keychain and nowhere else.
///
/// The same rule `MCPSecrets` exists for, for the same reason: Dictator's
/// settings live in a folder the user points at iCloud Drive or Dropbox, so a
/// key written into `settings.json` would be carried off this Mac by the sync
/// that is supposed to be carrying preferences. Keys go here; the settings
/// file holds only *which* backend was chosen.
enum SearchSecrets {
    static let service = "net.robgough.Dictator"

    private static func account(_ backend: SearchBackend) -> String {
        "search.\(backend.rawValue).apiKey"
    }

    static func value(for backend: SearchBackend) -> String? {
        // Screenshot runs must never read a real key into a capture.
        if ScreenshotMode.isActive { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(backend),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func setValue(_ value: String, for backend: SearchBackend) {
        if ScreenshotMode.isActive { return }
        remove(backend)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(backend),
            kSecValueData as String: Data(trimmed.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Dictator] Couldn't store the \(backend.label) key: OSStatus \(status)")
        }
    }

    static func remove(_ backend: SearchBackend) {
        if ScreenshotMode.isActive { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(backend),
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func has(_ backend: SearchBackend) -> Bool {
        value(for: backend) != nil
    }
}
