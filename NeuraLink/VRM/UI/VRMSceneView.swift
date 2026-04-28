//
//  VRMSceneView.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit
import SwiftUI

/// Embeds an existing `MTKView` instance into the SwiftUI view hierarchy.
struct MetalKitView: UIViewRepresentable {
    let mtkView: MTKView
    func makeUIView(context: Context) -> MTKView { mtkView }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

public struct VRMSceneView: View {
    let modelURL: URL?
    @State private var state = VRMMetalState()
    @State private var settings = OpenAISettings.shared
    // Tracks whether the initial model load (app launch) has completed.
    // On app launch we never auto-connect; subsequent model switches reconnect
    // using whatever is currently enabled in settings.
    @State private var isFirstLoad = true

    public init(modelURL: URL?) {
        self.modelURL = modelURL
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            primaryContent
        }
        .task(id: modelURL) { await loadModel() }
        // Connect when the user explicitly enables a setting — not on launch.
        .onChange(of: settings.isLocalLLMEnabled) { _, enabled in
            if enabled { startAIConnection() }
        }
        .onChange(of: settings.isEnabled) { _, enabled in
            if enabled { startAIConnection() }
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
        if !state.isMetalAvailable {
            previewPlaceholder
        } else if modelURL == nil {
            noModelView
        } else if let error = state.errorMessage {
            errorView(message: error)
        } else if state.isEnvironmentReady {
            MetalKitView(mtkView: state.mtkView)
                .ignoresSafeArea()
                .overlay {
                    if !state.isModelLoaded {
                        modelSwitchingOverlay
                    }
                }
        } else {
            loadingView
        }
    }

    private var previewPlaceholder: some View {
        ContentUnavailableView(
            "Preview Mode",
            systemImage: "cube.transparent",
            description: Text("Metal rendering is not available in Xcode Previews.")
        )
    }

    private var noModelView: some View {
        ContentUnavailableView(
            "No Model Found",
            systemImage: "cube.transparent",
            description: Text("Add **Sonya.vrm** or **Ekaterina.vrm** to the Xcode project, make sure the target membership is set to NeuraLink, then rebuild.")
        )
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(.purple)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var modelSwitchingOverlay: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text("Loading model…")
                .font(.subheadline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView(
            "Model Unavailable",
            systemImage: "exclamationmark.triangle.fill",
            description: Text(message)
        )
    }

    @MainActor
    private func loadModel() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard state.isMetalAvailable, let url = modelURL else { return }
        state.clear()

        let characterName = url.deletingPathExtension().lastPathComponent
        RealtimeChatState.shared.selectedCharacterName = characterName

        // Stop any active AI before switching characters.
        OpenAIRealtimeManager.shared.disconnect()
        LocalLLMManager.shared.stop()

        do {
            guard let device = state.mtkView.device else { return }
            let model = try await VRMModel.load(from: url, device: device)
            state.display(model)
        } catch {
            state.errorMessage = error.localizedDescription
        }

        // On the first load (app launch) never auto-connect — the user must
        // explicitly enable a setting. On subsequent model switches, reconnect
        // using whatever is currently active in settings.
        if isFirstLoad {
            isFirstLoad = false
        } else {
            startAIConnection()
        }
    }

    private func startAIConnection() {
        if settings.isLocalLLMEnabled {
            LocalLLMManager.shared.startListening()
        } else if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        }
    }
}
