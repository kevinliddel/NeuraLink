//
//  MemoryExportSheet.swift
//  NeuraLink
//
//  "Export memory…" options + share sheet (docs/MEMORY_OWNERSHIP_PLAN.md §M2).
//

import SwiftUI

struct MemoryExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var includeConversations = true
    @State private var everything = false
    @State private var isBuilding = false
    @State private var fileURL: URL?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $includeConversations) {
                        InfoToggleLabel(
                            title: "Include conversations",
                            info: "Adds every chat's messages. Without it the file holds facts, memories, insights, summaries and the journal.")
                    }
                    if includeConversations {
                        Toggle(isOn: $everything) {
                            InfoToggleLabel(
                                title: "Every message",
                                info: "Off keeps the last \(MemoryExporter.messageCap) messages of each chat to keep the file small.")
                        }
                    }
                } footer: {
                    Text("A JSON file you own. Vectors are left out; everything else is human-readable.")
                }

                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share \(fileURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            build()
                        } label: {
                            HStack {
                                Label("Prepare export", systemImage: "doc.badge.gearshape")
                                Spacer()
                                if isBuilding { ProgressView() }
                            }
                        }
                        .disabled(isBuilding)
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Export memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: includeConversations) { _, _ in fileURL = nil }
            .onChange(of: everything) { _, _ in fileURL = nil }
        }
    }

    private func build() {
        isBuilding = true
        errorText = nil
        Task {
            do {
                fileURL = try await MemoryExporter.shared.export(includeConversations: includeConversations, everything: everything)
            } catch {
                errorText = "Export failed: \(error.localizedDescription)"
            }
            isBuilding = false
        }
    }
}
