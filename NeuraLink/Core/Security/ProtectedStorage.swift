//
//  ProtectedStorage.swift
//  NeuraLink
//
//  iOS Data Protection helper for app-private storage. Owns the
//  `Application Support/private/` directory and the API for applying a
//  protection class to files inside it.
//
//  Phase 2 of the security audit remediation plan. See
//  `docs/security_audit_plan.md` §3.2 (Path A — Data Protection).
//
//  Design notes:
//    - Stateless namespace `enum`, same pattern as `SecureStore`.
//    - Protection class is `.completeUntilFirstUserAuthentication`:
//        * Files are unreadable from a cold-boot extraction until the user
//          unlocks the device for the first time after boot.
//        * Once unlocked, files remain readable for the rest of the boot
//          cycle (including while the screen is locked again), which keeps
//          background features that may fire post-screen-lock working.
//        * `.complete` would be stricter but would lock out any code path
//          that runs while the screen is dimmed/locked — the app currently
//          has no `UIBackgroundModes` so this is a future concern, but the
//          chosen class is the conservative match.
//    - The parent directory is marked `isExcludedFromBackup` so its
//      contents do not get copied to iCloud / iTunes backups even when
//      backups are encrypted. Files created inside the directory inherit
//      the protection class.
//
//  Created by Dedicatus on 21/05/2026.
//

import Foundation

// MARK: - Errors

enum ProtectedStorageError: Error, CustomStringConvertible {
    /// The directory could not be created at the given URL.
    case directoryCreationFailed(URL, Error)

    /// `setAttributes`/`setResourceValues` failed for the given URL.
    case attributeSetFailed(URL, Error)

    /// Could not locate the platform's Application Support directory.
    case applicationSupportUnavailable(Error)

    var description: String {
        switch self {
        case .directoryCreationFailed(let url, let err):
            return "ProtectedStorage: failed to create \(url.path): \(err)"
        case .attributeSetFailed(let url, let err):
            return "ProtectedStorage: failed to set attributes on \(url.path): \(err)"
        case .applicationSupportUnavailable(let err):
            return "ProtectedStorage: Application Support unavailable: \(err)"
        }
    }
}

// MARK: - API

enum ProtectedStorage {

    /// Subdirectory of Application Support that holds sensitive on-device
    /// state. Bare-named to match the convention other apps use; the parent
    /// directory already carries the bundle identifier so collisions across
    /// apps cannot happen.
    private static let privateSubdir = "private"

    /// Returns the `Application Support/private/` directory, creating it on
    /// first call with the protection class applied and the backup
    /// exclusion flag set. Subsequent calls are cheap — they only verify
    /// the directory exists. Throws if the directory can't be created or
    /// the attributes can't be applied; the caller decides whether to
    /// fall back to an unprotected location or surface the error.
    static func privateApplicationSupportURL() throws -> URL {
        let fileManager = FileManager.default

        let appSupport: URL
        do {
            appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
        } catch {
            throw ProtectedStorageError.applicationSupportUnavailable(error)
        }

        let privateDir = appSupport.appendingPathComponent(privateSubdir, isDirectory: true)

        if fileManager.fileExists(atPath: privateDir.path) {
            return privateDir
        }

        do {
            try fileManager.createDirectory(
                at: privateDir,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ])
        } catch {
            throw ProtectedStorageError.directoryCreationFailed(privateDir, error)
        }

        // Backup exclusion is a URL resource value, not a posix attribute,
        // so it goes through a separate API. Done on the directory rather
        // than each file because URL resource values for descendants follow
        // the parent in iCloud's backup walk.
        do {
            var mutable = privateDir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        } catch {
            throw ProtectedStorageError.attributeSetFailed(privateDir, error)
        }

        return privateDir
    }

    /// Applies the protection class to a single file. No-op if the file
    /// doesn't exist (callers can pass speculative paths like the
    /// transient `.sqlite-journal` sibling without first checking).
    ///
    /// Files created inside `privateApplicationSupportURL()` inherit the
    /// class from the directory, so this is mostly a belt-and-suspenders
    /// call for files that may have been created before the directory
    /// attribute was applied — e.g. a `.sqlite` left over from a relocation
    /// migration.
    static func protect(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            try fileManager.setAttributes(
                [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: url.path)
        } catch {
            throw ProtectedStorageError.attributeSetFailed(url, error)
        }
    }
}
