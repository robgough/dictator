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
        // Screenshot mode never touches the real keychain — an unsigned
        // capture build asking for the signed app's items raises a password
        // prompt, and it has no business reading them anyway.
        if ScreenshotMode.isActive { return nil }
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
        if ScreenshotMode.isActive { return false }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// What a save actually did — shown under the key field, because a key
    /// that silently didn't save looks exactly like one that did until the
    /// first meeting fails.
    enum SaveOutcome: Equatable {
        case saved(synced: Bool)
        /// Asked to sync, but iCloud Keychain refused, so it's on this Mac.
        case savedLocallyInstead
        case cleared
        case failed(OSStatus)
    }

    /// Writes (or clears) a provider's key.
    ///
    /// Delete-then-add rather than `SecItemUpdate`: `kSecAttrSynchronizable`
    /// is part of an item's primary key, so toggling iCloud sync has to
    /// recreate the item, and a single code path for both cases is one fewer
    /// thing to get wrong. An empty or whitespace-only value deletes.
    ///
    /// A synchronizable item lives in the data-protection keychain, which
    /// needs a keychain-access-groups entitlement this app doesn't carry
    /// (Developer ID, not sandboxed, no provisioning profile), so that write
    /// fails with `errSecMissingEntitlement`. It used to fail silently —
    /// with sync on, no key was ever saved — so now it falls back to a key
    /// on this Mac and says so.
    @discardableResult
    static func save(_ value: String?, account: String, synchronizable: Bool) -> SaveOutcome {
        if ScreenshotMode.isActive { return .failed(errSecNotAvailable) }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        delete(account: account)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return .cleared }

        if synchronizable {
            let status = add(data, account: account, synchronizable: true)
            if status == errSecSuccess { return .saved(synced: true) }
            NSLog("[DictatorMeetings] iCloud Keychain write refused for \(account): OSStatus \(status); saving on this Mac instead")
        }
        let status = add(data, account: account, synchronizable: false)
        if status != errSecSuccess {
            NSLog("[DictatorMeetings] Keychain write failed for \(account): OSStatus \(status)")
            return .failed(status)
        }
        return synchronizable ? .savedLocallyInstead : .saved(synced: false)
    }

    private static func add(_ data: Data, account: String, synchronizable: Bool) -> OSStatus {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrLabel as String: "Dictator Meetings API key",
            kSecAttrDescription as String: "API key for a Dictator Meetings note-writing provider",
        ]
        if synchronizable {
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        } else {
            attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Whether this build can write iCloud Keychain items at all — probed
    /// once with a throwaway item. The settings toggle is only honest when
    /// this is true.
    static let iCloudSyncAvailable: Bool = {
        if ScreenshotMode.isActive { return false }
        let account = "__sync-probe__"
        let status = add(Data("probe".utf8), account: account, synchronizable: true)
        delete(account: account)
        return status == errSecSuccess
    }()

    /// Removes a provider's key, both the local and the synchronizable item.
    static func delete(account: String) {
        if ScreenshotMode.isActive { return }
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
            save(existing, account: account, synchronizable: synchronizable)
        }
    }
}
