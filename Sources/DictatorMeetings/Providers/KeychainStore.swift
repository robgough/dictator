import Foundation
import Security

/// API keys for the cloud providers. The ONLY place a key is ever written.
///
/// Keys never enter `MeetingsSettings` (and therefore never enter
/// `meetings-settings.json`, which lives in the user's synced folder and would
/// carry a plaintext secret into iCloud Drive / Dropbox). The settings blob
/// holds only `ProviderConfig.keychainAccount`, which is the provider's id.
///
/// Items are generic passwords under service `net.robgough.DictatorMeetings`,
/// account = provider id. `MeetingsSettings.keychainSyncEnabled` controls
/// `kSecAttrSynchronizable`: off (the default) pins the key to this Mac's
/// login keychain; on lets iCloud Keychain carry it to the user's other Macs.
/// Reads always search both, so flipping the toggle never loses a key that's
/// already there.
enum KeychainStore {
    static let service = "net.robgough.DictatorMeetings"

    /// The stored key for a provider, or nil when there isn't one. Searches
    /// synchronizable and non-synchronizable items alike.
    static func get(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty
        else { return nil }
        return string
    }

    /// True when a key exists, without pulling the secret into memory. Used by
    /// the Providers tab so the row can say "Key saved" without ever rendering
    /// one.
    static func has(account: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Writes (or clears) a provider's key.
    ///
    /// Delete-then-add rather than `SecItemUpdate`: `kSecAttrSynchronizable`
    /// is part of an item's primary key, so toggling iCloud sync has to
    /// recreate the item, and a single code path for both cases is one fewer
    /// thing to get wrong. An empty or whitespace-only value deletes.
    ///
    /// Returns false when the write failed — the caller surfaces that rather
    /// than silently leaving the provider keyless.
    @discardableResult
    static func set(_ value: String?, account: String, synchronizable: Bool) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        delete(account: account)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return true }

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Dictator Meetings API key",
            kSecAttrDescription as String: "API key for a Dictator Meetings note-writing provider",
        ]
        attributes[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!
        if !synchronizable {
            // Only meaningful on a local item; a synchronizable item's
            // accessibility is fixed by iCloud Keychain.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[DictatorMeetings] Keychain write failed for \(account): OSStatus \(status)")
            return false
        }
        return true
    }

    /// Removes a provider's key, both the local and the synchronizable item.
    static func delete(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("[DictatorMeetings] Keychain delete failed for \(account): OSStatus \(status)")
        }
    }

    /// Re-writes every listed provider's key under the new synchronizable
    /// flag. Called when the user flips "Sync keys with iCloud Keychain" — the
    /// flag is part of an item's identity, so existing keys have to move
    /// rather than being picked up by the new setting.
    static func migrateSynchronizable(accounts: [String], to synchronizable: Bool) {
        for account in accounts {
            guard let existing = get(account: account) else { continue }
            _ = set(existing, account: account, synchronizable: synchronizable)
        }
    }
}
