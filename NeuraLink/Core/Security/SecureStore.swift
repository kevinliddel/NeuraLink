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

    fileprivate var service: String {
        switch self {
        case .openAIAPIKey: return "com.neuralink.openai"
        }
    }

    fileprivate var account: String {
        switch self {
        case .openAIAPIKey: return "apiKey"
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

    var description: String {
        switch self {
        case .unhandledStatus(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "SecureStore Keychain error \(status): \(msg)"
        case .invalidStringEncoding:
            return "SecureStore UTF-8 encoding/decoding failure"
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
}
