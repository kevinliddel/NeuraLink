//
//  UserSettings.swift
//  NeuraLink
//
//  Manages persistent user profile information (name, gender, birthday).
//  Injects profile + live date/time into the AI system prompt for personalized greetings.
//  The profile and photo persist through UserProfileStore (protected, not
//  backed up); the scene preferences below stay in UserDefaults.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation
import SwiftUI

@Observable
final class UserSettings {
    static let shared = UserSettings()

    private let showEnvironmentKey = "com.neuralink.user.showEnvironment"
    private let selectedEnvironmentKey = "com.neuralink.user.selectedEnvironment"
    private let selectedCharacterKey = "com.neuralink.user.selectedCharacter"
    private let windKey = "com.neuralink.user.wind"
    private let windForImportedKey = "com.neuralink.user.windForImported"
    var showEnvironment: Bool {
        didSet { UserDefaults.standard.set(showEnvironment, forKey: showEnvironmentKey) }
    }
    
    var selectedEnvironment: String {
        didSet { UserDefaults.standard.set(selectedEnvironment, forKey: selectedEnvironmentKey) }
    }

    /// A light breeze in the characters' hair and clothes (SkyWind). On by
    /// default for the bundled characters, whose springs it was tuned on.
    var wind: Bool {
        didSet { UserDefaults.standard.set(wind, forKey: windKey) }
    }

    /// The breeze for imported characters too: off by default, as their
    /// springs were tuned for still air.
    var windForImported: Bool {
        didSet { UserDefaults.standard.set(windForImported, forKey: windForImportedKey) }
    }

    /// Lowercased character name/slug of the last selected model, so the
    /// choice survives relaunch (a plain pointer, not sensitive — same tier
    /// as `selectedEnvironment`). Nil = never chosen → factory default.
    var selectedCharacter: String? {
        didSet { UserDefaults.standard.set(selectedCharacter, forKey: selectedCharacterKey) }
    }
    
    /// Posted when name, gender or birthday changes, so the agentic memory
    /// can re-sync the facts it keeps about who the user is.
    nonisolated static let profileDidChange = Notification.Name("com.neuralink.user.profileDidChange")

    // Each setter persists only its own field: under default MainActor
    // isolation these didSets also fire during init, so they must not touch
    // the other properties.
    var name: String {
        didSet {
            UserProfileStore.set(\.name, name)
            announceProfileChange(changed: name != oldValue)
        }
    }

    var gender: String {
        didSet {
            UserProfileStore.set(\.gender, gender)
            announceProfileChange(changed: gender != oldValue)
        }
    }

    var birthday: Date {
        didSet {
            UserProfileStore.set(\.birthday, birthday.timeIntervalSince1970)
            announceProfileChange(changed: birthday != oldValue)
        }
    }

    private func announceProfileChange(changed: Bool) {
        guard changed else { return }
        NotificationCenter.default.post(name: Self.profileDidChange, object: nil)
    }

    /// JPEG bytes of the user's profile photo, or nil. Kept in-memory for
    /// `@Observable` change tracking; mirrored to a protected file by
    /// UserProfileStore.
    var profileImageData: Data? {
        didSet { UserProfileStore.saveImage(profileImageData) }
    }

    /// Decoded profile image, if set. Sidebar/transcript header use this.
    var profileImage: UIImage? {
        profileImageData.flatMap(UIImage.init(data:))
    }

    private init() {
        if UserDefaults.standard.object(forKey: showEnvironmentKey) == nil {
            self.showEnvironment = true
        } else {
            self.showEnvironment = UserDefaults.standard.bool(forKey: showEnvironmentKey)
        }
        
        self.selectedEnvironment = UserDefaults.standard.string(forKey: selectedEnvironmentKey) ?? "city"
        self.wind = UserDefaults.standard.object(forKey: windKey) as? Bool ?? true
        self.windForImported = UserDefaults.standard.bool(forKey: windForImportedKey)
        self.selectedCharacter = UserDefaults.standard.string(forKey: selectedCharacterKey)

        let profile = UserProfileStore.load()
        self.name = profile.name
        self.gender = profile.gender
        self.birthday = profile.birthday == 0 ? Date() : Date(timeIntervalSince1970: profile.birthday)

        self.profileImageData = UserProfileStore.loadImage()
    }

    /// Returns a formatted string to be injected into the AI's system prompt.
    var systemPromptContext: String {
        var context = "\n[Current Context]\n"

        let now = Date()
        let localZone = TimeZone.current

        let dayDateFmt = DateFormatter()
        dayDateFmt.timeZone = localZone
        dayDateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        context += "- Current Day & Date: \(dayDateFmt.string(from: now))\n"

        let timeFmt = DateFormatter()
        timeFmt.timeZone = localZone
        timeFmt.dateFormat = "h:mm a"
        context += "- Current Time: \(timeFmt.string(from: now))\n"

        context += "[End of Current Context]\n"
        context += "\n[User Information]\n"

        if !name.isEmpty {
            context += "- User Name: \(name)\n"
        }

        if gender != "Prefer not to say" {
            context += "- User Gender: \(gender)\n"
        }

        let birthdayFmt = DateFormatter()
        birthdayFmt.dateStyle = .long
        context += "- User Birthday: \(birthdayFmt.string(from: birthday))\n"

        let ageComponents = Calendar.current.dateComponents([.year], from: birthday, to: now)
        if let age = ageComponents.year, age > 0 {
            context += "- User Age: \(age)\n"
        }

        context += "[End of User Information]\n"
        return context
    }
}
