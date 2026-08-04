//
//  CharacterImportFlow.swift
//  NeuraLink
//
//  View modifier hosting the whole VRM import pipeline:
//
//    fileImporter → staging/validation progress → confirm sheet
//    (CharacterImportConfirmSheet) → finalize into protected storage →
//    persona setup (the existing PersonaSettingsView, which already edits
//    prompt + voice for every engine mode).
//
//  Attach via `.characterImportFlow(isPickerPresented:onImported:)`. The
//  `.vrm`/`.glb` UTTypes are declared in Info.plist
//  (UTImportedTypeDeclarations); validation decides what's really a VRM,
//  not the extension.
//

import SwiftUI
import UniformTypeIdentifiers

extension View {
    func characterImportFlow(
        isPickerPresented: Binding<Bool>,
        onImported: @escaping (ImportedCharacter) -> Void
    ) -> some View {
        modifier(CharacterImportFlow(
            isPickerPresented: isPickerPresented, onImported: onImported))
    }
}

struct CharacterImportFlow: ViewModifier {
    @Binding var isPickerPresented: Bool
    var onImported: (ImportedCharacter) -> Void

    @State private var isStaging = false
    @State private var candidate: VRMImportCandidate?
    /// Staged files that still need cleanup if the confirm sheet goes away
    /// without a successful finalize (Cancel or swipe-down).
    @State private var pendingDiscard: VRMImportCandidate?
    @State private var importError: String?
    @State private var setupCharacter: ImportedCharacter?

    private static let allowedTypes: [UTType] = [
        UTType(importedAs: "com.neuralink.vrm"),
        UTType(importedAs: "com.neuralink.glb")
    ]

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    stage(url)
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .sheet(item: $candidate, onDismiss: discardIfPending) { candidate in
                CharacterImportConfirmSheet(
                    candidate: candidate,
                    onConfirm: { displayName, cardImage in
                        finalize(candidate, displayName: displayName, cardImage: cardImage)
                    },
                    onCancel: { self.candidate = nil }
                )
            }
            .sheet(item: $setupCharacter) { character in
                NavigationStack {
                    PersonaSettingsView(modelID: character.slug)
                }
            }
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .overlay {
                if isStaging { stagingOverlay }
            }
    }

    // MARK: - Pipeline steps

    private func stage(_ url: URL) {
        isStaging = true
        Task {
            do {
                let staged = try await VRMImportService.shared.stage(pickedURL: url)
                pendingDiscard = staged
                candidate = staged
            } catch {
                importError = (error as? VRMImportError)?.errorDescription
                    ?? error.localizedDescription
            }
            isStaging = false
        }
    }

    private func finalize(_ candidate: VRMImportCandidate, displayName: String, cardImage: Data?) {
        Task {
            do {
                let row = try await VRMImportService.shared.finalize(
                    candidate, displayName: displayName, customThumbnailPNG: cardImage)
                pendingDiscard = nil
                self.candidate = nil
                ImportedCharacterStore.shared.noteExternalMutation()
                VRMModelRegistry.shared.refresh()
                onImported(row)
                setupCharacter = row
            } catch {
                // finalize cleans up after itself on failure — the staged
                // files are consumed either way, so nothing left to discard.
                pendingDiscard = nil
                self.candidate = nil
                importError = (error as? VRMImportError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func discardIfPending() {
        guard let leftover = pendingDiscard else { return }
        pendingDiscard = nil
        Task { await VRMImportService.shared.discard(leftover) }
    }

    // MARK: - Progress overlay

    private var stagingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.3)
                    .tint(.white)
                Text("Validating model…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text("Checking the file, rig, and expressions")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
        .transition(.opacity)
    }
}
