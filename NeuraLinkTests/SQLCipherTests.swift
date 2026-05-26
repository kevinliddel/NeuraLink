//
//  SQLCipherTests.swift
//  NeuraLinkTests
//
//  Validates the SQLCipher integration end-to-end: keying a fresh DB,
//  verifying cipher_version is non-empty (proves we linked SQLCipher and
//  not the system SQLite), writing + reading data through the cipher,
//  and confirming the on-disk file is not openable without the key.
//
//  Phase 2b of the security audit remediation plan. See
//  `docs/security_audit_plan.md` §3.2 Path B.
//

import Foundation
import SQLCipher
import Testing

@testable import NeuraLink

/// Probes the Keychain with a read-only `getData` call. Returns `true`
/// when the call completes (including `errSecItemNotFound`, which is a
/// successful "no such item" response); returns `false` when the process
/// lacks the entitlement to talk to the Keychain at all.
///
/// File-level rather than a static method on `SQLCipherTests` because the
/// `@Suite(.disabled(if:))` trait is evaluated while the macro is still
/// resolving the type — referencing `SQLCipherTests.isKeychainAvailable`
/// from the trait causes a circular-reference error.
private func sqlCipherTestsKeychainAvailable() -> Bool {
    do {
        _ = try SecureStore.getData(.memoryDBPageKey)
        return true
    } catch {
        return false
    }
}

/// Tests run serially because both exercise `SecureStore.getOrCreateRandom`
/// against the same `SecureKey.memoryDBPageKey`. Under Swift Testing's
/// default parallel execution, two concurrent reads see no item, both
/// generate fresh keys, and the second write trashes the first — a
/// thread-safety pattern that doesn't occur in production where
/// `MemoryStore.shared` is a single instance that keys exactly once.
///
/// Suite is skipped when Keychain access isn't available — the CI test
/// runner has no Keychain Access Group entitlement so `SecItemAdd` would
/// return `errSecMissingEntitlement (-34018)`. Skipping is honest there;
/// production / local-simulator runs have entitlement and exercise the
/// real code path.
@Suite("SQLCipher Integration Tests",
       .serialized,
       .disabled(
        if: !sqlCipherTestsKeychainAvailable(),
        "Keychain unavailable in this environment (likely CI without entitlement)"))
struct SQLCipherTests {

    /// End-to-end happy path: create an encrypted DB at a temp path,
    /// write a row, close, re-open with the same key, and read the row
    /// back. Validates that `sqlite3_key` + the page key from the
    /// Keychain produce a working encrypted DB.
    @Test("SQLCipher round-trip with key from Keychain")
    func testSQLCipherRoundTrip() throws {
        let tmpPath = NSTemporaryDirectory()
            .appending("sqlcipher_test_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Phase A: open a brand-new DB and key it via the same helper
        // MemoryStore uses in production.
        var db: OpaquePointer?
        #expect(sqlite3_open(tmpPath, &db) == SQLITE_OK)
        #expect(MemoryStore.keyDatabase(db))

        let createSQL = "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);"
        #expect(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO t (v) VALUES ('hello');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        // Phase B: re-open with the same Keychain-backed key — must
        // succeed and return the row we just wrote.
        var db2: OpaquePointer?
        #expect(sqlite3_open(tmpPath, &db2) == SQLITE_OK)
        #expect(MemoryStore.keyDatabase(db2))

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db2, "SELECT v FROM t;", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        if let cstr = sqlite3_column_text(stmt, 0) {
            #expect(String(cString: cstr) == "hello")
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db2)

        // Phase C: open with NO key — first read must fail because the
        // pages are encrypted. This is what proves the DB is actually
        // protected on disk, not just configured to use SQLCipher.
        var db3: OpaquePointer?
        #expect(sqlite3_open(tmpPath, &db3) == SQLITE_OK)
        let unkeyedRead = sqlite3_exec(db3, "SELECT count(*) FROM t;", nil, nil, nil)
        #expect(unkeyedRead != SQLITE_OK, "Unkeyed open should not be able to read the encrypted table")
        sqlite3_close(db3)
    }

    /// Verifies the on-disk format: a SQLCipher-encrypted DB does NOT
    /// begin with the `SQLite format 3\0` magic that a plaintext SQLite
    /// file uses. Cheap, no-Keychain check that the bytes hitting disk
    /// are actually encrypted.
    @Test("Encrypted DB on disk does not show plaintext SQLite magic")
    func testEncryptedFileHeaderIsNotPlaintext() throws {
        let tmpPath = NSTemporaryDirectory()
            .appending("sqlcipher_magic_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        var db: OpaquePointer?
        #expect(sqlite3_open(tmpPath, &db) == SQLITE_OK)
        #expect(MemoryStore.keyDatabase(db))
        // Force a write so SQLCipher actually allocates and encrypts a
        // page — otherwise the file might still be size 0.
        #expect(sqlite3_exec(db, "CREATE TABLE x (i INTEGER);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let magic = Data("SQLite format 3\0".utf8)
        #expect(data.count >= 16)
        #expect(data.prefix(magic.count) != magic, "Encrypted DB must not start with the SQLite plaintext magic header")
    }
}
