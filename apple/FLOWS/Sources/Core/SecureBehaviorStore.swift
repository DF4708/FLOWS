// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CryptoKit
import Foundation
import Security

/// ENCRYPTED-AT-REST storage for everything the app learns about the DRIVER —
/// where they go, when, how they drive, and what they pick.
///
/// The threat this answers: a phone that is lost, stolen, seized, or resold
/// with its filesystem readable. iOS Data Protection already covers a locked
/// device, but these files must survive `afterFirstUnlock` (background
/// training and arrival recording happen with the screen off), which leaves
/// them readable to anything that can walk the container on a running or
/// jailbroken device. A destination history is a map of someone's life —
/// home, work, doctor, church, the shelter they visited — so it gets its own
/// envelope: AES-GCM with a 256-bit key that lives ONLY in the Keychain, is
/// marked device-only, and is never synced to iCloud or copied into a backup.
/// Without the key the files are noise.
///
/// Sealed with AES-GCM (authenticated): tampering is detected, not silently
/// consumed — a corrupted or forged behavior file reads as "no data" rather
/// than injecting bogus training rows.
///
/// The contract callers rely on: data is decrypted only into memory, only
/// while it is being read or trained on, and is re-sealed on every write.
/// Nothing plaintext ever touches disk — including the training export the
/// Rust trainer consumes, which is the most sensitive file of the set (raw
/// trip rows).
enum SecureBehaviorStore {
    private static let service = "com.flows.app.behavior"

    /// Which key a file is sealed under.
    ///
    /// `.behavior` is everything the app LEARNS, and "Erase everything FLOWS
    /// has learned" destroys that key. `.favorites` is what the driver
    /// TYPED — Home, Work — which the same button must not touch: losing a
    /// saved home address because you asked the app to forget your habits
    /// would be a betrayal of the button's own wording. Separate key,
    /// separate lifetime; both device-only and absent from backups.
    enum Keyspace: String {
        case behavior = "behavior-data-key-v1"
        case favorites = "favorites-key-v1"
    }

    /// The device-only data key, created on first use and never exported.
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` mirrors SecureStore:
    /// available to background work after the first unlock, absent from
    /// backups, never synced.
    static func key(_ keyspace: Keyspace = .behavior) -> SymmetricKey? {
        let account = keyspace.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        // First run (or the item was purged): mint one.
        var bytes = Data(count: 32)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base) == errSecSuccess
        }
        guard ok else { return nil }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(add as CFDictionary)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        add.removeAll()
        return SymmetricKey(data: bytes)
    }

    /// Seal and write atomically. `false` means nothing was written — callers
    /// must treat that as "this learning did not persist", never as success.
    @discardableResult
    static func write(_ data: Data, to url: URL,
                      keyspace: Keyspace = .behavior) -> Bool {
        guard let key = key(keyspace),
              let sealed = try? AES.GCM.seal(data, using: key).combined else {
            FlowsDiag.logThrottled(
                key: "behavior.sealFail", .warn, "privacy",
                "could not seal behavior data — not persisted this time")
            return false
        }
        do {
            try sealed.write(to: url, options: .atomic)
            // Belt and braces with the app's own envelope: ask the OS for the
            // strongest protection class that still permits background work.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Read and open the envelope. nil = absent, unreadable, wrong key, or
    /// FAILED AUTHENTICATION (tampered). All four are "no data" — a behavior
    /// file that does not authenticate is never partially trusted.
    static func read(_ url: URL, keyspace: Keyspace = .behavior) -> Data? {
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        guard let key = key(keyspace) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: raw),
              let opened = try? AES.GCM.open(box, using: key) else {
            FlowsDiag.log(.warn, "privacy",
                          "behavior file did not authenticate — ignoring \(url.lastPathComponent)")
            return nil
        }
        return opened
    }

    /// Codable convenience.
    static func load<T: Decodable>(_ type: T.Type, from url: URL,
                                   keyspace: Keyspace = .behavior) -> T? {
        read(url, keyspace: keyspace).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, to url: URL,
                                   keyspace: Keyspace = .behavior) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return write(data, to: url, keyspace: keyspace)
    }

    /// Read a behavior file, transparently upgrading a PLAINTEXT store left
    /// by an earlier build. Earlier versions wrote unencrypted JSON to these
    /// exact paths, so the upgrade is in-place: if the sealed read fails but
    /// the bytes parse as JSON, they are re-sealed at the same path and the
    /// plaintext is overwritten before being replaced. A driver who updates
    /// keeps their history and stops leaving it in the clear, with no action
    /// and no data loss.
    static func readMigrating(_ url: URL) -> Data? {
        if let opened = read(url) { return opened }
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty,
              (try? JSONSerialization.jsonObject(with: raw)) != nil else { return nil }
        // Overwrite the plaintext bytes in place, THEN write the sealed copy.
        var noise = Data(count: raw.count)
        _ = noise.withUnsafeMutableBytes { buf in
            buf.baseAddress.map { SecRandomCopyBytes(kSecRandomDefault, raw.count, $0) }
        }
        try? noise.write(to: url, options: .atomic)
        guard write(raw, to: url) else { return raw }
        FlowsDiag.log(.info, "privacy",
                      "upgraded \(url.lastPathComponent) to encrypted storage")
        return raw
    }

    /// Best-effort secure delete: overwrite with random bytes of the same
    /// length, then remove. On a flash-translation layer this cannot
    /// guarantee the old blocks are gone — it removes the easy recovery, and
    /// the encryption above is what actually protects the data.
    static func shred(_ url: URL) {
        if let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 0 {
            var noise = Data(count: size)
            _ = noise.withUnsafeMutableBytes { raw in
                raw.baseAddress.map { SecRandomCopyBytes(kSecRandomDefault, size, $0) }
            }
            try? noise.write(to: url, options: .atomic)
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop the encryption key, so any copy of a behavior file that escaped
    /// — a backup, a forensic image — is permanently undecryptable.
    ///
    /// Shredding the plaintext is not enough on its own: each store shreds
    /// its OWN file when the driver erases, but until the key goes too, an
    /// escaped ciphertext is still readable. This is the last step of
    /// "erase everything FLOWS has learned", and without it that promise
    /// was only half kept.
    /// The ONE queue every behaviour store seals on.
    ///
    /// It exists so erasing is ordered. The stores each had a private queue
    /// and the erase button deleted the key synchronously, so a snapshot
    /// enqueued a moment earlier could run AFTER the key was gone — find no
    /// key, mint a fresh one, and write the driver's learned history back to
    /// disk perfectly readable. The confirmation said "back to knowing
    /// nothing" while the data was being re-sealed behind it.
    ///
    /// One FIFO queue means every pending seal lands under the OLD key
    /// before the delete runs, leaving ciphertext nothing can open.
    static let persistQueue = DispatchQueue(
        label: "com.flows.behavior.persist", qos: .utility)

    /// Destroys the LEARNED-data key only. The favourites key is the
    /// driver's own typed addresses and is not part of "what FLOWS learned".
    static func destroyKey() {
        persistQueue.async {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: Keyspace.behavior.rawValue,
            ] as CFDictionary)
            FlowsDiag.log(.info, "privacy", "behavior data erased and key destroyed")
        }
    }
}
