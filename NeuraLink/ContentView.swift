//
//  ContentView.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import SwiftUI

/// Root view that hosts the VRM Viewer.
struct ContentView: View {

    @State private var selectedModelURL: URL? = VRMModelRegistry.defaultModel?.url
    @State private var aiState = RealtimeChatState.shared
    @State private var showModelSelection = false
    @State private var isMenuExpanded = false

    var body: some View {
        NavigationStack {
            ZStack {
                VRMSceneView(modelURL: selectedModelURL)
                RealtimeChatOverlay()

                if showModelSelection {
                    VStack {
                        Spacer()
                        ModelSelectionOverlay(
                            selectedModelURL: $selectedModelURL,
                            models: VRMModelRegistry.all,
                            onSelection: {
                                withAnimation { showModelSelection = false }
                            }
                        )
                        .padding(.horizontal, 16)
                        Spacer()
                    }
                    .background(Color.black.opacity(0.6).ignoresSafeArea())
                    .onTapGesture {
                        withAnimation { showModelSelection = false }
                    }
                    .transition(.opacity)
                    .zIndex(100)
                }

            }
            .overlay(alignment: .topTrailing) {
                ExpandableFABMenu(
                    isExpanded: $isMenuExpanded,
                    onSettings: { aiState.showSettings = true },
                    onModelSelection: { withAnimation { showModelSelection.toggle() } }
                )
            }
            .navigationTitle("NeuraLink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { menuToggleButton }
            .allowsHitTesting(!aiState.showSettings)
            .sheet(isPresented: $aiState.showSettings) {
                AISettingsView()
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var menuToggleButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    isMenuExpanded.toggle()
                }
            } label: {
                Image(systemName: isMenuExpanded ? "xmark" : "square.grid.2x2")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

}

// MARK: VRM Model Registry

/// Locates `.vrm` and `.glb` model files inside the app bundle.
///
/// **Search order:**
/// 1. Known names looked up directly via `Bundle.main.url(forResource:withExtension:)`.
/// 2. Anything inside a `Models/` folder reference, if one is present.
///
/// Entries are deduplicated by lowercased name.
enum VRMModelRegistry {

    struct Entry {
        let name: String
        let url: URL
    }

    static let all: [Entry] = {
        var seen = Set<String>()
        return (namedEntries() + folderEntries())
            .filter { seen.insert($0.name.lowercased()).inserted }
    }()

    static var defaultModel: Entry? {
        all.first { $0.name.lowercased() == "ekaterina" } ?? all.first
    }

    private static func namedEntries() -> [Entry] {
        [
            ("Sonya", "vrm"), ("Ekaterina", "vrm"),
            ("Sonya", "glb"), ("Ekaterina", "glb")
        ]
        .compactMap { name, ext -> Entry? in
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                return nil
            }
            return Entry(name: name, url: url)
        }
    }

    private static func folderEntries() -> [Entry] {
        guard let dir = Bundle.main.url(forResource: "Models", withExtension: nil) else {
            return []
        }
        let urls =
            (try? FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return
            urls
            .filter { ["vrm", "glb"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }
}

// MARK: Preview

#Preview {
    ContentView()
}
