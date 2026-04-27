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

    public init(modelURL: URL?) {
        self.modelURL = modelURL
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            primaryContent
        }
        .task(id: modelURL) { await loadModel() }
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
        connectAI(characterName: characterName)
        do {
            guard let device = state.mtkView.device else { return }
            let model = try await VRMModel.load(from: url, device: device)
            state.display(model)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func connectAI(characterName: String) {
        let settings = OpenAISettings.shared
        let chatState = RealtimeChatState.shared
        chatState.selectedCharacterName = characterName
        
        // Stop any existing connections
        OpenAIRealtimeManager.shared.disconnect()
        LocalLLMManager.shared.stop()
        
        if settings.isLocalLLMEnabled {
            LocalLLMManager.shared.startListening()
        } else if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        }
    }
}
