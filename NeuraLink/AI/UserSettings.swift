//
//  UserSettings.swift
//  NeuraLink
//
//  Manages persistent user profile information (name, gender, birthday).
//  This data is injected into the AI's system prompt to provide personal context.
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
    
    private init() {}
    
    var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }
    
    var gender: String {
        get { UserDefaults.standard.string(forKey: genderKey) ?? "Prefer not to say" }
        set { UserDefaults.standard.set(newValue, forKey: genderKey) }
    }
    
    var birthday: Date {
        get {
            let interval = UserDefaults.standard.double(forKey: birthdayKey)
            return interval == 0 ? Date() : Date(timeIntervalSince1970: interval)
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: birthdayKey) }
    }
    
    /// Returns a formatted string to be injected into the AI's system prompt.
    var systemPromptContext: String {
        var context = "\n[User Information]\n"
        
        if !name.isEmpty {
            context += "- User Name: \(name)\n"
        }
        
        if gender != "Prefer not to say" {
            context += "- User Gender: \(gender)\n"
        }
        
        // Calculate age or just provide birthday
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        context += "- User Birthday: \(formatter.string(from: birthday))\n"
        
        let ageComponents = Calendar.current.dateComponents([.year], from: birthday, to: Date())
        if let age = ageComponents.year, age > 0 {
            context += "- User Age: \(age)\n"
        }
        
        context += "[End of User Information]\n"
        return context
    }
}
