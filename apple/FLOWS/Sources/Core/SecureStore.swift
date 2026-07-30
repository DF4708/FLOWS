// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import Security

/// Keychain-backed string storage for the app's few genuinely-sensitive
/// values — an OAuth client secret and the driver's medical notes. These were
/// in `UserDefaults`, which is an unencrypted plist that is included in device
/// backups (and readable off a jailbroken or unlocked device); a credential
/// and health data do not belong there.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable in
/// the background after the first unlock (so the crash-report flow can include
/// medical notes without the screen being active), never synced to iCloud, and
/// never copied to another device in a backup.
enum SecureStore {
    private static let service = "com.flows.app.secure"

    /// Store a value (nil/empty deletes the item).
    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent replace
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Read a value, or nil if absent.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One-time migration of a value that used to live in UserDefaults: move it
    /// into the Keychain and scrub the plaintext copy. Returns the resolved
    /// value (Keychain first, else the migrated default).
    static func migrateFromDefaults(key: String, defaultsKey: String) -> String {
        if let secure = get(key) { return secure }
        let legacy = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !legacy.isEmpty {
            set(legacy, for: key)
            UserDefaults.standard.removeObject(forKey: defaultsKey)  // scrub plaintext
        }
        return legacy
    }
}
