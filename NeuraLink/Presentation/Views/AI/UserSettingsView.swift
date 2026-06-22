//
//  UserSettingsView.swift
//  NeuraLink
//
//  A settings view for editing the user's profile information.
//
//  Created by Dedicatus on 09/05/2026.
//

import SwiftUI
import PhotosUI

struct UserSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = UserSettings.shared
    @State private var memorySettings = MemorySettings.shared
    @State private var photoItem: PhotosPickerItem?

    let genders = ["Male", "Female", "Prefer not to say"]

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Profile Information")) {
                    HStack {
                        Text("Photo")
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                            profileAvatar
                        }
                        .buttonStyle(.plain)
                    }
                    if settings.profileImageData != nil {
                        Button("Remove Photo", role: .destructive) {
                            settings.profileImageData = nil
                            photoItem = nil
                        }
                    }

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

                Section(header: Text("Memory")) {
                    Toggle("Memory Enabled", isOn: Bindable(memorySettings).isEnabled)
                        .listRowSeparator(memorySettings.isEnabled ? .hidden : .automatic)

                    if memorySettings.isEnabled {
                        Toggle("Store AI Responses", isOn: Bindable(memorySettings).storeAIResponses)
                            .listRowSeparator(.hidden)

                        Picker("Auto-forget", selection: Bindable(memorySettings).autoForgetDays) {
                            Text("Never").tag(0)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .listRowSeparator(.hidden)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Memory Quality")
                                Spacer()
                                Text(memorySettings.similarityFloor, format: .number.precision(.fractionLength(2)))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: Bindable(memorySettings).similarityFloor, in: 0.3...0.7, step: 0.05)
                            Text("Higher values surface fewer, more relevant memories.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        MemoryTimelineView()
                    } label: {
                        Label("Memory & Facts", systemImage: "brain")
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
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                    // Downscale so the stored profile photo stays small.
                    settings.profileImageData = Self.downscaledJPEG(data, maxDimension: 512) ?? data
                }
            }
        }
    }

    @ViewBuilder private var profileAvatar: some View {
        if let img = settings.profileImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .foregroundStyle(.secondary)
        }
    }

    /// Re-encodes image data as a JPEG no larger than `maxDimension` on its
    /// long edge. Returns nil if the data isn't a decodable image.
    private static func downscaledJPEG(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

struct EnvironmentOptionView: View {
    let name: String
    let imageName: String
    let isSelected: Bool
    let action: () -> Void
    
    private let image: UIImage?

    init(name: String, imageName: String, isSelected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.imageName = imageName
        self.isSelected = isSelected
        self.action = action
        self.image = Self.loadImage(named: imageName)
    }

    private static func loadImage(named imageName: String) -> UIImage? {
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
