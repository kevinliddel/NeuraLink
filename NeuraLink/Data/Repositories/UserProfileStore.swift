//
//  UserProfileStore.swift
//  NeuraLink
//
//  Persists the user's profile (name, gender, birthday) and profile photo
//  under `Application Support/private/`, so they get the same treatment as
//  the conversation DB: Data Protection and no iCloud / iTunes backup.
//  They used to live in `UserDefaults` and at the Application Support root,
//  both of which are backed up.
//
//  `UserSettings` stays the in-memory source of truth; this type only
//  reads at launch and writes one field at a time, so a setter never has to
//  touch the other properties (see the didSet note on `UserSettings`).
//
//  Created by Dedicatus on 04/11/2026.
//

import Foundation

enum UserProfileStore {

    struct Profile: Codable, Equatable {
        var name = ""
        var gender = UserProfileStore.defaultGender
        /// Seconds since 1970; 0 = never set.
        var birthday: TimeInterval = 0
    }

    static let defaultGender = "Prefer not to say"

    private static let profileFileName = "user_profile.json"
    private static let imageFileName = "user_profile.jpg"
    private static let migrationFlag = "com.neuralink.migration.userProfileProtected.v1"

    /// Pre-migration `UserDefaults` keys.
    enum LegacyKey {
        static let name = "com.neuralink.user.name"
        static let gender = "com.neuralink.user.gender"
        static let birthday = "com.neuralink.user.birthday"
        static let all = [name, gender, birthday]
    }

    // MARK: - API

    /// The stored profile, migrating the legacy copy on first call.
    static func load() -> Profile {
        migrateIfNeeded()
        guard let url = profileURL() else { return Profile() }
        return read(at: url) ?? Profile()
    }

    /// Writes one field, leaving the others as stored.
    static func set<Value>(_ keyPath: WritableKeyPath<Profile, Value>, _ value: Value) {
        guard let url = profileURL() else { return }
        update(at: url) { $0[keyPath: keyPath] = value }
    }

    static func loadImage() -> Data? {
        migrateIfNeeded()
        guard let url = imageURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func saveImage(_ data: Data?) {
        guard let url = imageURL() else { return }
        if let data {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            try? ProtectedStorage.protect(url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Location-explicit core (internal for tests)

    /// The profile at `url`, `Profile()` when none exists yet, or nil when
    /// the file exists but can't be read (e.g. before first unlock).
    static func read(at url: URL) -> Profile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return Profile() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Profile.self, from: data)) ?? Profile()
    }

    /// Read-modify-write. Skips the write when the file is unreadable, so a
    /// locked file is never overwritten with defaults.
    @discardableResult
    static func update(at url: URL, _ change: (inout Profile) -> Void) -> Bool {
        guard var profile = read(at: url) else { return false }
        change(&profile)
        return write(profile, to: url)
    }

    @discardableResult
    static func write(_ profile: Profile, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(profile),
            (try? data.write(to: url, options: .atomic)) != nil
        else { return false }
        try? ProtectedStorage.protect(url)
        return true
    }

    /// Copies the legacy profile out of `defaults` and moves the legacy
    /// photo, then deletes the originals. Never overwrites a profile or
    /// photo that already exists at the new location, so a retry after a
    /// partial run can't roll back newer edits. Returns true once done.
    @discardableResult
    static func migrateLegacy(
        defaults: UserDefaults, profileURL: URL, imageURL: URL, legacyImageURL: URL
    ) -> Bool {
        guard !defaults.bool(forKey: migrationFlag) else { return true }
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: profileURL.path) {
            var profile = Profile()
            if let name = defaults.string(forKey: LegacyKey.name) { profile.name = name }
            if let gender = defaults.string(forKey: LegacyKey.gender) { profile.gender = gender }
            profile.birthday = defaults.double(forKey: LegacyKey.birthday)
            guard write(profile, to: profileURL) else { return false }
        }

        if fileManager.fileExists(atPath: legacyImageURL.path) {
            if fileManager.fileExists(atPath: imageURL.path) {
                try? fileManager.removeItem(at: legacyImageURL)
            } else {
                guard (try? fileManager.moveItem(at: legacyImageURL, to: imageURL)) != nil else { return false }
                try? ProtectedStorage.protect(imageURL)
            }
        }

        LegacyKey.all.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(true, forKey: migrationFlag)
        return true
    }

    // MARK: - Locations

    private static func profileURL() -> URL? {
        try? ProtectedStorage.privateApplicationSupportURL().appendingPathComponent(profileFileName)
    }

    private static func imageURL() -> URL? {
        try? ProtectedStorage.privateApplicationSupportURL().appendingPathComponent(imageFileName)
    }

    private static func migrateIfNeeded() {
        guard let profileURL = profileURL(), let imageURL = imageURL(),
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let migrated = migrateLegacy(
            defaults: .standard, profileURL: profileURL, imageURL: imageURL,
            legacyImageURL: support.appendingPathComponent(imageFileName))
        if !migrated {
            nlLog("[UserProfileStore] Profile migration incomplete — will retry next launch.", level: .warning)
        }
    }
}
