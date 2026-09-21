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
    static let service = "com.flows.app.secure"

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

/// Keychain items outlive the app: iOS keeps them when FLOWS is deleted, so a
/// reinstall found the last install's medical notes, trip-share contacts,
/// account tokens and data keys waiting — while the privacy policy says
/// deleting the app deletes its data. Nothing runs at deletion, so the first
/// launch of a fresh install clears FLOWS's own Keychain items instead.
enum FreshInstall {
    /// Set at every launch. Preferences go with the app, so no marker means
    /// this install has never launched.
    static let markerKey = "flows.installed"
    /// Every Keychain service FLOWS stores under.
    static let keychainServices = [SecureStore.service, SecureBehaviorStore.service]

    /// A fresh install: no marker, no FLOWS preference and no file in
    /// Application Support. Builds from before the marker left the other
    /// two behind (every launch stamps `flows.lastUsed`), so an update never
    /// wipes; anything unclear keeps the Keychain as it is.
    static func isFresh(markerPresent: Bool, preferenceKeys: [String],
                        supportFileCount: Int) -> Bool {
        !markerPresent && supportFileCount == 0
            && !preferenceKeys.contains { $0.hasPrefix("flows.") }
    }

    /// First thing at launch, before anything reads the Keychain. iPhone
    /// only: a Mac app's container, preferences included, stays after it is
    /// deleted, so there a reinstall is not a fresh start either way.
    static func clearLeftoversIfFresh(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: markerKey) == nil else { return }
        #if os(iOS)
        let keys = Bundle.main.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0) }
            .map { Array($0.keys) } ?? []
        let files = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
            .count ?? 0
        if isFresh(markerPresent: false, preferenceKeys: keys, supportFileCount: files) {
            for service in keychainServices {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ] as CFDictionary)
            }
            FlowsDiag.log(.info, "privacy", "fresh install: cleared Keychain items an earlier install left")
        }
        #endif
        defaults.set(true, forKey: markerKey)
    }
}
