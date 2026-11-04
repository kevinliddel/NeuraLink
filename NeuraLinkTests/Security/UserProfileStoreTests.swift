//
//  UserProfileStoreTests.swift
//  NeuraLinkTests
//
//  The profile moved out of UserDefaults into the protected private dir:
//  the one-shot migration, its no-rollback guarantee, and single-field
//  writes that leave the other fields alone. Runs against a temp dir and a
//  throwaway defaults suite, never the app's real profile.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("User profile store", .serialized)
struct UserProfileStoreTests {

    @MainActor
    private struct Sandbox {
        let dir: URL
        let defaults: UserDefaults
        let suiteName: String
        var profileURL: URL { dir.appendingPathComponent("user_profile.json") }
        var imageURL: URL { dir.appendingPathComponent("user_profile.jpg") }
        var legacyImageURL: URL { dir.appendingPathComponent("legacy_user_profile.jpg") }

        func migrate() -> Bool {
            UserProfileStore.migrateLegacy(
                defaults: defaults, profileURL: profileURL, imageURL: imageURL, legacyImageURL: legacyImageURL)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeSandbox() throws -> Sandbox {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suiteName = "UserProfileStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return Sandbox(dir: dir, defaults: defaults, suiteName: suiteName)
    }

    @Test("Migration moves the legacy profile and photo, then clears the originals")
    func migrationMovesLegacyData() throws {
        let box = try makeSandbox()
        defer { box.tearDown() }
        box.defaults.set("Rado", forKey: UserProfileStore.LegacyKey.name)
        box.defaults.set("Male", forKey: UserProfileStore.LegacyKey.gender)
        box.defaults.set(946_684_800.0, forKey: UserProfileStore.LegacyKey.birthday)
        try Data("jpeg".utf8).write(to: box.legacyImageURL)

        #expect(box.migrate())

        let profile = try #require(UserProfileStore.read(at: box.profileURL))
        #expect(profile == UserProfileStore.Profile(name: "Rado", gender: "Male", birthday: 946_684_800))
        #expect(try Data(contentsOf: box.imageURL) == Data("jpeg".utf8))
        #expect(!FileManager.default.fileExists(atPath: box.legacyImageURL.path))
        for key in UserProfileStore.LegacyKey.all {
            #expect(box.defaults.object(forKey: key) == nil)
        }
    }

    @Test("A retried migration never overwrites a newer profile")
    func migrationDoesNotRollBack() throws {
        let box = try makeSandbox()
        defer { box.tearDown() }
        box.defaults.set("Old name", forKey: UserProfileStore.LegacyKey.name)
        #expect(UserProfileStore.write(UserProfileStore.Profile(name: "New name"), to: box.profileURL))

        #expect(box.migrate())

        #expect(UserProfileStore.read(at: box.profileURL)?.name == "New name")
    }

    @Test("Migration runs once")
    func migrationRunsOnce() throws {
        let box = try makeSandbox()
        defer { box.tearDown() }
        #expect(box.migrate())
        try FileManager.default.removeItem(at: box.profileURL)
        box.defaults.set("Late", forKey: UserProfileStore.LegacyKey.name)

        #expect(box.migrate())

        #expect(!FileManager.default.fileExists(atPath: box.profileURL.path))
    }

    @Test("Writing one field keeps the others")
    func singleFieldUpdate() throws {
        let box = try makeSandbox()
        defer { box.tearDown() }
        let original = UserProfileStore.Profile(name: "Rado", gender: "Male", birthday: 1_000)
        #expect(UserProfileStore.write(original, to: box.profileURL))

        #expect(UserProfileStore.update(at: box.profileURL) { $0.name = "Hery" })

        let updated = try #require(UserProfileStore.read(at: box.profileURL))
        #expect(updated == UserProfileStore.Profile(name: "Hery", gender: "Male", birthday: 1_000))
    }

    @Test("A missing profile reads as defaults")
    func missingProfileReadsDefaults() throws {
        let box = try makeSandbox()
        defer { box.tearDown() }
        #expect(UserProfileStore.read(at: box.profileURL) == UserProfileStore.Profile())
    }
}
