//
//  SecureStore.swift
//  NeuraLink
//
//  Thin wrapper around `kSecClassGenericPassword` Keychain Services for
//  storing app secrets (API keys, future per-store encryption keys, etc.).
//
//  Phase 1 of the security audit remediation plan. See
//  `docs/security_audit_plan.md` §3.1.
//
//  Design notes:
//    - Stateless namespace `enum` — no instance state, no singleton lifecycle.
//    - Every item is bound to `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
//        * Unreadable while the device is locked from a cold boot (protects
//          against extraction of a powered-off device).
//        * Never synced via iCloud Keychain and never restored to a different
//          device — a fresh install on a new device starts without the secret,
//          which is the safe default for a key the user has to deliberately
//          re-enter.
//    - All API surfaces throw `SecureStoreError`; callers decide whether to
//      surface the failure or log-and-continue.
//
//  Created by Dedicatus on 21/05/2026.
//

import Foundation
import Security

// MARK: - Keys

/// Identifies a single secret stored in the Keychain. Each case maps to a
/// stable `(service, account)` pair — changing these strings would orphan the
/// existing Keychain item on every user's device, so treat them as a schema.
enum SecureKey {
    case openAIAPIKey
    /// 32-byte random page key for the SQLCipher-backed conversation DB.
    /// Generated on first use via `SecureStore.getOrCreateRandom`. Distinct
    /// service from `openAIAPIKey` so attribute-level access policies can
    /// evolve independently.
    case memoryDBPageKey

    fileprivate var service: String {
        switch self {
        case .openAIAPIKey: return "com.neuralink.openai"
        case .memoryDBPageKey: return "com.neuralink.memory"
        }
    }

    fileprivate var account: String {
        switch self {
        case .openAIAPIKey: return "apiKey"
        case .memoryDBPageKey: return "dbPageKey"
        }
    }
}

// MARK: - Errors

enum SecureStoreError: Error, CustomStringConvertible {
    /// The Keychain returned an `OSStatus` we don't know how to handle.
    case unhandledStatus(OSStatus)

    /// The stored bytes could not be decoded as UTF-8, or the value to store
    /// could not be encoded. Indicates corruption or a programmer error.
    case invalidStringEncoding

    /// `SecRandomCopyBytes` failed while provisioning a fresh random secret.
    /// Surfaces the underlying status so the caller can decide whether to
    /// retry or surface the failure to the user.
    case randomGenerationFailed(OSStatus)

    var description: String {
        switch self {
        case .unhandledStatus(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "SecureStore Keychain error \(status): \(msg)"
        case .invalidStringEncoding:
            return "SecureStore UTF-8 encoding/decoding failure"
        case .randomGenerationFailed(let status):
            return "SecureStore SecRandomCopyBytes failed (status \(status))"
        }
    }
}

// MARK: - API

enum SecureStore {

    /// Stores `value` under `key`. Overwrites any existing item.
    ///
    /// Empty strings are stored as zero-length data rather than deleted —
    /// `delete(_:)` is the explicit way to remove an entry. This keeps the
    /// "has the user ever set this?" question separate from "is the value
    /// currently empty?", which callers may care about for migration logic.
    static func set(_ value: String, for key: SecureKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw SecureStoreError.invalidStringEncoding
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecureStoreError.unhandledStatus(updateStatus)
            }
        default:
            throw SecureStoreError.unhandledStatus(addStatus)
        }
    }

    /// Returns the stored value for `key`, or `nil` if no item exists.
    /// Throws on Keychain errors other than "not found".
    static func get(_ key: SecureKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                throw SecureStoreError.invalidStringEncoding
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    /// Removes the stored value for `key`. Succeeds silently if the item does
    /// not exist — idempotent by design so migration paths can call it
    /// without first checking existence.
    static func delete(_ key: SecureKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    // MARK: - Binary value API

    /// Stores raw `Data` under `key`. Overwrites any existing item. The
    /// `Data` overload exists for binary secrets like SQLCipher page keys
    /// where UTF-8 round-tripping through the `String` API would discard
    /// non-textual bytes.
    static func set(_ value: Data, for key: SecureKey) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = value
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [kSecValueData as String: value]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecureStoreError.unhandledStatus(updateStatus)
            }
        default:
            throw SecureStoreError.unhandledStatus(addStatus)
        }
    }

    /// Returns the raw stored bytes for `key`, or `nil` if no item exists.
    /// Distinct name from `get(_:) -> String?` because Swift can't overload
    /// on return type alone — keeping the String API source-compatible.
    static func getData(_ key: SecureKey) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.unhandledStatus(status)
        }
    }

    /// Returns the stored bytes for `key`, generating a cryptographically
    /// random `bytes`-length value and persisting it on first call. Useful
    /// for provisioning a per-install secret (e.g. SQLCipher page key) that
    /// is stable for the life of the install but never leaves the Keychain
    /// in plaintext form.
    ///
    /// `SecRandomCopyBytes` is the system CSPRNG — calls into the Secure
    /// Enclave on Apple silicon; on simulator it falls back to the kernel
    /// PRNG, which is fine for testing.
    static func getOrCreateRandom(_ key: SecureKey, bytes: Int) throws -> Data {
        if let existing = try getData(key) {
            return existing
        }

        var fresh = Data(count: bytes)
        let status = fresh.withUnsafeMutableBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, bytes, base)
        }
        guard status == errSecSuccess else {
            throw SecureStoreError.randomGenerationFailed(status)
        }

        try set(fresh, for: key)
        return fresh
    }
}
