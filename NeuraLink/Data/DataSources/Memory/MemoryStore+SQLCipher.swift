//
//  MemoryStore+SQLCipher.swift
//  NeuraLink
//
//  Optional zero-knowledge layer on top of Phase 2a (file-level Data
//  Protection). When the user opts in via the `sqlcipherEnabled` flag,
//  the conversation DB is encrypted page-by-page with AES-CBC + HMAC
//  using a 32-byte random key stored in the Keychain. This survives
//  scenarios where iOS Data Protection might be bypassed (e.g. jailbreak
//  exploits that lift class keys) at the cost of an extra dependency and
//  a one-shot plaintext-to-encrypted conversion.
//
//  Phase 2b of the security audit remediation plan. See
//  `docs/security_audit_plan.md` §3.2 Path B and §3.7 (future passphrase
//  mode, which builds on this).
//
//  Design notes:
//    - `sqlcipherEnabled` (UserDefaults) is the user's intent.
//    - `sqlcipherActive.v1` (UserDefaults) is the realised state — set
//      only after a successful conversion / fresh-creation. The two flags
//      can diverge if a conversion attempt fails; the next launch will
//      retry.
//    - The page key is a 32-byte CSPRNG output stored in the Keychain
//      (`SecureKey.memoryDBPageKey`). Lost key → unreadable DB; that is
//      the point. The key never leaves the Secure Enclave-backed store
//      in any form the OS could include in a backup.
//
//  Created by Dedicatus on 21/05/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Feature flags

    /// UserDefaults key: user's intent to encrypt the DB at the page level.
    /// Public surface that the (future) Settings UI / Phase 7 passphrase
    /// flow flips. Reading is cheap; we re-check on every launch.
    static let sqlcipherEnabledFlag = "com.neuralink.security.sqlcipherEnabled"

    /// UserDefaults key: the realised state — set once a successful
    /// conversion (or fresh-encrypted creation) has completed. The launch
    /// path uses this to decide whether `sqlite3_key` must be called.
    static let sqlcipherActiveFlag = "com.neuralink.security.sqlcipherActive.v1"

    /// True when the user has opted into SQLCipher encryption. Reads
    /// `UserDefaults` so the flag can be flipped from any settings UI
    /// without restarting the singleton.
    static var isSQLCipherEnabled: Bool {
        UserDefaults.standard.bool(forKey: sqlcipherEnabledFlag)
    }

    /// True when the DB on disk is actually SQLCipher-encrypted. May lag
    /// `isSQLCipherEnabled` by one launch if the previous conversion
    /// attempt failed.
    static var isSQLCipherActive: Bool {
        UserDefaults.standard.bool(forKey: sqlcipherActiveFlag)
    }

    // MARK: - Keying

    /// Calls `sqlite3_key` on the just-opened DB handle with the 32-byte
    /// page key from the Keychain, then sanity-checks that SQLCipher (not
    /// the system SQLite) is actually answering by reading
    /// `PRAGMA cipher_version`. Returns true on success; false logs and
    /// returns so the caller can decide to bail.
    ///
    /// Must be called immediately after `sqlite3_open` and before any
    /// other DB operation — SQLCipher refuses to key a DB that has
    /// already been touched.
    static func keyDatabase(_ db: OpaquePointer?) -> Bool {
        guard let db = db else { return false }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.memoryDBPageKey, bytes: 32)
        } catch {
            nlLog("[MemoryStore] Could not obtain page key: \(error)", level: .error)
            return false
        }

        let keyStatus = key.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return SQLITE_ERROR }
            return sqlite3_key(db, base, Int32(key.count))
        }
        guard keyStatus == SQLITE_OK else {
            nlLog("[MemoryStore] sqlite3_key failed: status=\(keyStatus)", level: .error)
            return false
        }

        // `PRAGMA cipher_version` returns the SQLCipher version string —
        // the system SQLite doesn't implement this pragma, so a non-empty
        // result is proof we linked against the right library.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA cipher_version;", -1, &stmt, nil) == SQLITE_OK else {
            nlLog("[MemoryStore] cipher_version prepare failed", level: .error)
            return false
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0)
        else {
            nlLog(
                "[MemoryStore] cipher_version returned no rows — link error?",
                level: .error)
            return false
        }
        let version = String(cString: cstr)
        nlLog("[MemoryStore] SQLCipher active, cipher_version=\(version)", level: .info)
        return true
    }

    // MARK: - Conversion (plaintext → SQLCipher)

    /// Converts an existing plaintext DB at `path` into a SQLCipher-
    /// encrypted DB using `sqlcipher_export`, then atomically replaces
    /// the file. Sets the `sqlcipherActive` flag only on success.
    ///
    /// Safe to call when `path` doesn't exist (fresh install): in that
    /// case the SQLite file simply doesn't exist yet and we just mark
    /// the active flag — `setupDatabase` will then `sqlite3_open` a fresh
    /// encrypted DB.
    ///
    /// Conversion strategy:
    ///   1. Open the plaintext DB at the original path.
    ///   2. ATTACH a sibling `encrypted` DB with KEY = our page key.
    ///   3. `SELECT sqlcipher_export('encrypted')` copies all tables.
    ///   4. DETACH and close.
    ///   5. Atomically replace the plaintext file with the encrypted one.
    ///   6. Set the active flag.
    static func convertPlaintextToSQLCipher(at path: String) {
        let fileManager = FileManager.default

        // Fresh install — no plaintext file exists. Nothing to convert;
        // just mark active so `setupDatabase` keys the new DB on creation.
        guard fileManager.fileExists(atPath: path) else {
            UserDefaults.standard.set(true, forKey: sqlcipherActiveFlag)
            nlLog("[MemoryStore] No plaintext DB found; marking SQLCipher active for fresh creation", level: .info)
            return
        }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.memoryDBPageKey, bytes: 32)
        } catch {
            nlLog("[MemoryStore] Conversion aborted, key unavailable: \(error)", level: .error)
            return
        }

        let encryptedPath = path + ".sqlcipher-tmp"
        // Stale temp from a prior aborted run — purge before we begin.
        try? fileManager.removeItem(atPath: encryptedPath)

        var src: OpaquePointer?
        guard sqlite3_open(path, &src) == SQLITE_OK else {
            nlLog("[MemoryStore] Conversion: cannot open plaintext source", level: .error)
            return
        }
        defer { sqlite3_close(src) }

        // SQLCipher accepts the key either as a passphrase (then derived
        // via PBKDF2) or as a 64-char hex literal `x'...'` (used as the
        // raw page key with no derivation). We have raw random bytes from
        // SecRandomCopyBytes, so the hex-literal form is the right shape.
        let hexKey = key.map { String(format: "%02x", $0) }.joined()
        let attachSQL = "ATTACH DATABASE ? AS encrypted KEY \"x'\(hexKey)'\";"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(src, attachSQL, -1, &stmt, nil) == SQLITE_OK else {
            nlLog("[MemoryStore] Conversion ATTACH prepare failed", level: .error)
            return
        }
        sqlite3_bind_text(stmt, 1, (encryptedPath as NSString).utf8String, -1, nil)
        let attachStatus = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard attachStatus == SQLITE_DONE else {
            nlLog("[MemoryStore] Conversion ATTACH step failed: \(attachStatus)", level: .error)
            return
        }

        let exportStatus = sqlite3_exec(src, "SELECT sqlcipher_export('encrypted');", nil, nil, nil)
        guard exportStatus == SQLITE_OK else {
            let errmsg = sqlite3_errmsg(src).map { String(cString: $0) } ?? "unknown"
            nlLog("[MemoryStore] sqlcipher_export failed: \(errmsg)", level: .error)
            return
        }

        _ = sqlite3_exec(src, "DETACH DATABASE encrypted;", nil, nil, nil)
        sqlite3_close(src)

        // Atomic replacement: `FileManager.replaceItemAt` writes to a
        // temp on the same volume, then renames over the original.
        // Crash mid-replace leaves either the old file or the new file
        // in place — never a torn write.
        do {
            let originalURL = URL(fileURLWithPath: path)
            let encryptedURL = URL(fileURLWithPath: encryptedPath)
            _ = try fileManager.replaceItemAt(originalURL, withItemAt: encryptedURL)

            // Clean up SQLite siblings that referenced the plaintext page
            // format — leaving them around would confuse the next open.
            for suffix in ["-journal", "-wal", "-shm"] {
                try? fileManager.removeItem(atPath: path + suffix)
            }
        } catch {
            nlLog("[MemoryStore] Conversion atomic replace failed: \(error)", level: .error)
            return
        }

        UserDefaults.standard.set(true, forKey: sqlcipherActiveFlag)
        nlLog(
            "[MemoryStore] DB converted to SQLCipher (key in Keychain, plaintext purged)",
            level: .info)
    }
}
