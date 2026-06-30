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
    @Bindable private var aiState = RealtimeChatState.shared
    private var camera = CameraManager.shared
    @State private var showModelSelection = false
    @State private var isMenuExpanded = false
    @State private var envLoad = EnvironmentLoadState.shared

    var body: some View {
        NavigationStack {
            ZStack {
                VRMSceneView(modelURL: selectedModelURL)
                
                if !aiState.isUIHidden {
                    RealtimeChatOverlay()
                    CameraOverlayView()
                }

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
                if !aiState.isUIHidden {
                    ExpandableFABMenu(
                        isExpanded: $isMenuExpanded,
                        onSettings: { aiState.showSettings = true },
                        onRelationship: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                aiState.showRelationshipBar = true
                            }
                        },
                        onModelSelection: { withAnimation { showModelSelection.toggle() } },
                        onCameraToggle: {
                            if camera.isActive {
                                camera.stop()
                            } else {
                                Task { await camera.requestPermissionAndStart() }
                            }
                        },
                        onPiP: {
                            PiPManager.shared.startPiP()
                        }
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                if !aiState.isUIHidden && aiState.showRelationshipBar {
                    RelationshipMeterBarOverlay()
                        .padding(.leading, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                if !aiState.isUIHidden && envLoad.isReady {
                    chatHistoryToggleButton
                    menuToggleButton
                }
            }
            .allowsHitTesting(!aiState.showSettings && !aiState.showUserSettings)
            .sheet(isPresented: $aiState.showSettings) {
                AISettingsView()
            }
            .sheet(isPresented: $aiState.showUserSettings) {
                UserSettingsView()
            }
            .overlay {
                if aiState.showChatSidebar {
                    ChatHistorySidebar(
                        aiState: aiState,
                        onNewChat: { startNewChatSession() },
                        onSelect: { convo in
                            aiState.viewingConversationID = convo.id
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                                aiState.showChatSidebar = false
                            }
                        },
                        onOpenProfile: {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                                aiState.showChatSidebar = false
                            }
                            aiState.showUserSettings = true
                        }
                    )
                    .zIndex(200)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { aiState.viewingConversationID != nil },
                set: { if !$0 { aiState.viewingConversationID = nil } }
            )) {
                if let cid = aiState.viewingConversationID {
                    ConversationTranscriptView(
                        conversationID: cid,
                        onClose: { aiState.viewingConversationID = nil },
                        onNewChat: {
                            aiState.viewingConversationID = nil
                            startNewChatSession()
                        }
                    )
                }
            }
            // Game-engine-style launch loading screen: held until the base
            // scene + the selected 3D environment mesh are ready (the
            // environment downloads on first launch), then fades out.
            .overlay {
                if !envLoad.isReady {
                    EnvironmentLoadingScreen()
                        .transition(.mist)
                        .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.8), value: envLoad.isReady)
            .task {
                // The reveal is normally driven by `environmentDidLoad` — fired
                // when the selected environment's mesh finishes downloading +
                // loading, on success OR failure — plus the `forceReady()` calls
                // on the no-model / no-Metal / load-error paths. On first
                // install the env GLB downloads from HF and can take well over
                // 30 s; URLSession's own request timeout already turns a stalled
                // download into an error (→ environmentDidLoad → reveal) within
                // ~60 s, so a healthy download must NEVER be cut off here — that
                // is the whole point of the loading screen.
                //
                // This is only a last-resort guard against a logic hang where
                // neither signal ever fires. The interval is deliberately long
                // so it cannot preempt a real (even slow) first-install
                // download. (Was 30 s, which fired mid-download and revealed an
                // empty scene on first launch.)
                try? await Task.sleep(nanoseconds: 600_000_000_000)  // 10 min
                if !envLoad.isReady {
                    nlLog(
                        "[EnvironmentLoadState] Reveal backstop fired after 600s without a ready signal — forcing reveal.",
                        level: .warning)
                    EnvironmentLoadState.shared.forceReady()
                }
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
            .accessibilityLabel("Menu")
        }
    }

    /// Opens the ChatGPT-style chat-history sidebar. Standalone button on the
    /// LEFT, separate from the right-side menu/FAB.
    @ToolbarContentBuilder
    private var chatHistoryToggleButton: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    aiState.showChatSidebar = true
                }
            } label: {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            .accessibilityLabel("Chat history")
        }
    }

    // MARK: - Session

    /// Starts a fresh chat session and returns to the live 3D avatar.
    /// Local LLM context resets automatically (the new conversation has no
    /// history); OpenAI's context is server-side, so we reconnect for a clean
    /// session.
    private func startNewChatSession() {
        ConversationStore.shared.startNewChat()
        aiState.clearTranscripts()

        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            OpenAIRealtimeManager.shared.disconnect()
            OpenAIRealtimeManager.shared.connect()
        }

        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            aiState.showChatSidebar = false
            aiState.viewingConversationID = nil
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
