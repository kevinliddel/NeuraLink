//
//  UserSettingsView.swift
//  NeuraLink
//
//  A settings view for editing the user's profile information.
//
//  Created by Antigravity on 09/05/2026.
//

import SwiftUI

struct UserSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = UserSettings.shared
    
    let genders = ["Male", "Female", "Prefer not to say"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Profile Information")) {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Your Name", text: Bindable(settings).name)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    
                    Picker("Gender", selection: Bindable(settings).gender) {
                        ForEach(genders, id: \.self) { gender in
                            Text(gender).tag(gender)
                        }
                    }
                    
                    DatePicker("Birthday", selection: Bindable(settings).birthday, displayedComponents: .date)
                }
                
                Section(footer: Text("This information is shared with the AI to personalize your experience. It is stored locally on your device.")) {
                    EmptyView()
                }
            }
            .navigationTitle("User Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    UserSettingsView()
}
