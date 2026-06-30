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
    @State private var photoItem: PhotosPickerItem?

    let genders = ["Male", "Female", "Prefer not to say"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    profilePhoto
                        .listRowBackground(Color.clear)
                }

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
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(EnvironmentCatalog.all) { option in
                                    EnvironmentOptionView(
                                        name: option.displayName,
                                        imageName: option.previewImage,
                                        isSelected: settings.selectedEnvironment == option.id
                                    ) {
                                        settings.selectedEnvironment = option.id
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        // Bleed the scroll to the cell edges so cards aren't clipped
                        // by the Form row's default content insets.
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                    }
                }

                Section(header: Text("Memory")) {
                    NavigationLink {
                        MemoryTimelineView()
                    } label: {
                        Label("Memory & Facts", systemImage: "brain")
                    }
                }
                
                Section(footer: Text("This information is shared with the AI to personalize your experience. It is stored locally on your device.")) {
                    EmptyView() // anchors the footer text
                }
            }
            .scrollIndicators(.hidden)
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

    /// Centered, tappable profile photo. The whole circle (incl. the camera
    /// badge) opens the picker to add/change; a small "x" badge on the image
    /// removes it.
    private var profilePhoto: some View {
        ZStack(alignment: .topTrailing) {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let img = settings.profileImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Circle()
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 42))
                                        .foregroundStyle(.secondary)
                                )
                        }
                    }
                    .frame(width: 104, height: 104)
                    .clipShape(Circle())

                    // Add / change affordance.
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: Circle())
                        .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 3))
                }
            }
            .buttonStyle(.plain)

            // Remove badge — sits on the image, only when a photo is set.
            if settings.profileImageData != nil {
                Button {
                    settings.profileImageData = nil
                    photoItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .accessibilityLabel("Remove photo")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
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
            .frame(width: 150, height: 150)
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
