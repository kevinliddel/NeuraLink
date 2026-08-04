//
//  CharacterImageSection.swift
//  NeuraLink
//
//  "Character Image" Form section shown in PersonaSettingsView for imported
//  characters only: preview of the current card image + PhotosPicker to
//  replace it + removal back to the letter placeholder. Self-contained
//  (owns its picker state) so PersonaSettingsView stays under the file-length
//  ceiling — writes go straight through ImportedCharacterStore.setThumbnail,
//  no Save button involvement.
//

import PhotosUI
import SwiftUI

struct CharacterImageSection: View {
    let slug: String

    @State private var photoItem: PhotosPickerItem?
    private var store = ImportedCharacterStore.shared

    init(slug: String) {
        self.slug = slug
    }

    private var currentImage: UIImage? {
        _ = store.lastUpdated  // re-read the file after setThumbnail
        guard let url = store.character(slug: slug)?.thumbnailURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        Section {
            HStack(spacing: 16) {
                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 60, height: 60)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 6) {
                    // Both controls share one Form row — without .borderless
                    // the whole row is a single tap target and BOTH fire on
                    // any tap (see the Save/Reset incident in PersonaSettings).
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(
                            currentImage == nil ? "Choose Image…" : "Change Image…",
                            systemImage: "photo")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    if currentImage != nil {
                        Button(role: .destructive) {
                            store.setThumbnail(slug: slug, imageData: nil)
                        } label: {
                            Label("Remove Image", systemImage: "trash")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Character Image")
        } footer: {
            Text("Shown on this character's card in the picker.")
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.setThumbnail(slug: slug, imageData: data)
                }
                photoItem = nil
            }
        }
    }
}
