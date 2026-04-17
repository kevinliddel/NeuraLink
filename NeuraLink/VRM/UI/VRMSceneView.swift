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
            if state.isModelLoaded {
                infoOverlay
            }
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
        } else if !state.isModelLoaded {
            loadingView
        } else {
            MetalKitView(mtkView: state.mtkView)
                .ignoresSafeArea()
                .opacity(state.modelAlpha)
                .animation(.easeIn(duration: 0.4), value: state.modelAlpha)
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
            Text("Loading model…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var infoOverlay: some View {
        Group {
            if let model = state.currentModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.meta.name ?? "Unknown Model")
                        .font(.headline)
                    Text(model.meta.version ?? "v1.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.meta.authors.first ?? "Unknown Author")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding()
            }
        }
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
        guard state.isMetalAvailable, let url = modelURL else { return }
        state.clear()
        autoConnectAI()
        do {
            guard let device = state.mtkView.device else { return }
            let model = try await VRMModel.load(from: url, device: device)
            state.display(model)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func autoConnectAI() {
        let ai = OpenAIRealtimeManager.shared
        let chatState = RealtimeChatState.shared
        guard OpenAISettings.shared.hasValidKey,
              chatState.status == .disconnected else { return }
        ai.connect()
    }
}
