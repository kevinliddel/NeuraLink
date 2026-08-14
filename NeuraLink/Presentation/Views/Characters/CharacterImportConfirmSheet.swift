//
//  CharacterImportConfirmSheet.swift
//  NeuraLink
//
//  Confirmation step of the VRM import flow: shows the staged candidate's
//  thumbnail, metadata, license permissions, and capability warnings; lets
//  the user pick the display name and (optionally) a custom card image from
//  Photos; and gates restricted-use models behind an explicit acknowledgment.
//  Import commits the files to protected storage (VRMImportService.finalize)
//  — Cancel discards the staging copy.
//

import PhotosUI
import SwiftUI

struct CharacterImportConfirmSheet: View {
    let candidate: VRMImportCandidate
    /// (displayName, customCardImage) — image nil means "use the thumbnail
    /// embedded in the VRM file" (or the placeholder when there is none).
    var onConfirm: (String, Data?) -> Void
    var onCancel: () -> Void

    @State private var displayName: String
    @State private var acknowledgedRestriction = false
    @State private var photoItem: PhotosPickerItem?
    @State private var customImageData: Data?

    init(
        candidate: VRMImportCandidate,
        onConfirm: @escaping (String, Data?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.candidate = candidate
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _displayName = State(initialValue: candidate.suggestedDisplayName)
    }

    private var report: VRMValidationReport { candidate.report }

    private var canImport: Bool {
        !report.isUseRestricted || acknowledgedRestriction
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                Section("Name") {
                    TextField("Character name", text: $displayName)
                }
                if !report.warnings.isEmpty {
                    warningsSection
                }
                licenseSection
            }
            .navigationTitle("Import Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { onConfirm(displayName, customImageData) }
                        .fontWeight(.semibold)
                        .disabled(!canImport)
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        customImageData = data
                    }
                }
            }
        }
    }

    // MARK: - Sections

    /// Custom pick → embedded VRM thumbnail → placeholder.
    private var cardImage: UIImage? {
        if let customImageData, let image = UIImage(data: customImageData) {
            return image
        }
        if let url = candidate.stagedThumbnailURL {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    private var previewSection: some View {
        Section {
            HStack(spacing: 16) {
                if let image = cardImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 72, height: 72)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let metaName = report.metaName {
                        Text(metaName).font(.headline)
                    }
                    Text("VRM \(report.specVersion) · \(report.fileSize / 1_048_576) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !report.authors.isEmpty {
                        Text("by \(report.authors.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(
                    customImageData == nil ? "Choose Card Image…" : "Change Card Image…",
                    systemImage: "photo")
            }
            if customImageData != nil {
                Button(role: .destructive) {
                    customImageData = nil
                    photoItem = nil
                } label: {
                    Label(
                        candidate.stagedThumbnailURL != nil
                            ? "Use Model's Thumbnail" : "Remove Image",
                        systemImage: "arrow.uturn.backward")
                }
            }
        } footer: {
            Text("The card image is shown in the character picker. It defaults to the thumbnail embedded in the VRM file.")
        }
    }

    private var warningsSection: some View {
        Section("Heads-up") {
            ForEach(report.warnings, id: \.self) { warning in
                Label {
                    Text(warning).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var licenseSection: some View {
        Section {
            if let permission = report.avatarPermission {
                LabeledContent("Avatar use", value: permission)
            }
            if let usage = report.commercialUsage {
                LabeledContent("Commercial use", value: usage)
            }
            // Web schemes only — the URL comes from the untrusted VRM file,
            // and a crafted value could otherwise open an arbitrary app.
            if let raw = report.licenseURL, let url = URL(string: raw),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link("View license", destination: url)
                    .font(.footnote)
            }
            if report.isUseRestricted {
                Toggle(isOn: $acknowledgedRestriction) {
                    Text("The author restricts this avatar to themselves. I confirm I'm the author or have their permission.")
                        .font(.footnote)
                }
            }
        } header: {
            Text("License")
        } footer: {
            Text("Permissions are declared by the model's author inside the VRM file. Please respect them.")
        }
    }
}
