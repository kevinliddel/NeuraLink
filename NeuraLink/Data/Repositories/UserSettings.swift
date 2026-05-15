//
//  UserSettings.swift
//  NeuraLink
//
//  Manages persistent user profile information (name, gender, birthday).
//  Injects profile + live date/time into the AI system prompt for personalized greetings.
//
//  Created by Antigravity on 09/05/2026.
//

import Foundation
import SwiftUI

@Observable
final class UserSettings {
    static let shared = UserSettings()
    
    private let nameKey = "com.neuralink.user.name"
    private let genderKey = "com.neuralink.user.gender"
    private let birthdayKey = "com.neuralink.user.birthday"
    private let showEnvironmentKey = "com.neuralink.user.showEnvironment"
    private let selectedEnvironmentKey = "com.neuralink.user.selectedEnvironment"
    var showEnvironment: Bool {
        didSet { UserDefaults.standard.set(showEnvironment, forKey: showEnvironmentKey) }
    }
    
    var selectedEnvironment: String {
        didSet { UserDefaults.standard.set(selectedEnvironment, forKey: selectedEnvironmentKey) }
    }
    
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: nameKey) }
    }
    
    var gender: String {
        didSet { UserDefaults.standard.set(gender, forKey: genderKey) }
    }
    
    var birthday: Date {
        didSet { UserDefaults.standard.set(birthday.timeIntervalSince1970, forKey: birthdayKey) }
    }
    
    private init() {
        if UserDefaults.standard.object(forKey: showEnvironmentKey) == nil {
            self.showEnvironment = true
        } else {
            self.showEnvironment = UserDefaults.standard.bool(forKey: showEnvironmentKey)
        }
        
        self.selectedEnvironment = UserDefaults.standard.string(forKey: selectedEnvironmentKey) ?? "city"
        self.name = UserDefaults.standard.string(forKey: "com.neuralink.user.name") ?? ""
        self.gender = UserDefaults.standard.string(forKey: "com.neuralink.user.gender") ?? "Prefer not to say"
        
        let interval = UserDefaults.standard.double(forKey: "com.neuralink.user.birthday")
        self.birthday = interval == 0 ? Date() : Date(timeIntervalSince1970: interval)
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
