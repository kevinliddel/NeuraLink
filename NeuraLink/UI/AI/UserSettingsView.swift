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
                
                Section(header: Text("Environment Settings")) {
                    Toggle("Show 3D Environment", isOn: Bindable(settings).showEnvironment)
                    
                    if settings.showEnvironment {
                        HStack(spacing: 16) {
                            EnvironmentOptionView(
                                name: "City",
                                imageName: "city",
                                isSelected: settings.selectedEnvironment == "city"
                            ) {
                                settings.selectedEnvironment = "city"
                            }
                            
                            EnvironmentOptionView(
                                name: "Campus",
                                imageName: "campus",
                                isSelected: settings.selectedEnvironment == "campus"
                            ) {
                                settings.selectedEnvironment = "campus"
                            }
                        }
                        .padding(.vertical, 8)
                    }
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

struct EnvironmentOptionView: View {
    let name: String
    let imageName: String
    let isSelected: Bool
    let action: () -> Void
    
    private var image: UIImage? {
        if let path = Bundle.main.path(forResource: imageName, ofType: "png", inDirectory: "Models/Environments") {
            return UIImage(contentsOfFile: path)
        }
        if let path = Bundle.main.path(forResource: imageName, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
        return UIImage(named: imageName)
    }
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                // Background Image
                Group {
                    if let uiImage = image {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.1)
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
                
                // Gradient Overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.3), .black.opacity(0.7)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                
                // Text and Selection Icon
                HStack {
                    Text(name)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .background(Circle().fill(.white))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .clipped()
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    UserSettingsView()
}
