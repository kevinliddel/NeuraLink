//
//  CharacterImportConfirmSheet.swift
//  NeuraLink
//
//  Confirmation step of the VRM import flow: shows the staged candidate's
//  thumbnail, metadata, license permissions, and capability warnings; lets
//  the user pick the display name; and gates restricted-use models behind an
//  explicit acknowledgment. Import commits the files to protected storage
//  (VRMImportService.finalize) — Cancel discards the staging copy.
//

import SwiftUI

struct CharacterImportConfirmSheet: View {
    let candidate: VRMImportCandidate
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @State private var displayName: String
    @State private var acknowledgedRestriction = false

    init(
        candidate: VRMImportCandidate,
        onConfirm: @escaping (String) -> Void,
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
                    Button("Import") { onConfirm(displayName) }
                        .fontWeight(.semibold)
                        .disabled(!canImport)
                }
            }
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            HStack(spacing: 16) {
                if let url = candidate.stagedThumbnailURL,
                   let image = UIImage(contentsOfFile: url.path) {
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
            if let raw = report.licenseURL, let url = URL(string: raw) {
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
