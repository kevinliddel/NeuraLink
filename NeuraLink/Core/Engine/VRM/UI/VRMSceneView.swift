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
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        mtkView.frame = container.bounds
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(mtkView)
        
        // Setup PiP
        PiPManager.shared.setupPiP(sourceView: container, mtkView: mtkView)
        
        return container
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

public struct VRMSceneView: View {
    let modelURL: URL?
    @State private var state: VRMMetalState?
    @State private var settings = OpenAISettings.shared
    @State private var appearance = AppearanceSettings.shared
    // Tracks whether the initial model load (app launch) has completed.
    // On app launch we never auto-connect; subsequent model switches reconnect
    // using whatever is currently enabled in settings.
    @State private var isFirstLoad = true
    @State private var toastMessage: String? = nil

    public init(modelURL: URL?) {
        self.modelURL = modelURL
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            if !UserSettings.shared.showEnvironment {
                Color.black.ignoresSafeArea()
                if let img = appearance.backgroundUIImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                }
            }
            primaryContent

            if let toastMessage {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.yellow)
                        Text(toastMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 10, y: 5)
                    .padding(.top, 20)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self.toastMessage = nil
                        }
                    }
                }
            }
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
        if let state {
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
        
        if state == nil {
            state = VRMMetalState()
        }
        guard let state else { return }

        guard state.isMetalAvailable, let url = modelURL else {
            // Nothing to render (preview / no Metal / no model) — don't hold the
            // launch loading screen on a scene that will never appear.
            EnvironmentLoadState.shared.forceReady()
            return
        }
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
            nlLog("[VRMSceneView] Failed to load model from \(url.path): \(error.localizedDescription)", level: .error)
            
            if let defaultEntry = VRMModelRegistry.defaultModel, defaultEntry.url != url {
                do {
                    nlLog("[VRMSceneView] Falling back to default model '\(defaultEntry.name)'")
                    guard let device = state.mtkView.device else { return }
                    let model = try await VRMModel.load(from: defaultEntry.url, device: device)
                    state.display(model)
                    toastMessage = "Couldn't load that avatar — using the default"
                } catch {
                    nlLog("[VRMSceneView] Fallback model load failed: \(error.localizedDescription)", level: .error)
                    state.errorMessage = "Failed to load model and default fallback failed: \(error.localizedDescription)"
                    EnvironmentLoadState.shared.forceReady()
                }
            } else {
                state.errorMessage = error.localizedDescription
                EnvironmentLoadState.shared.forceReady()
            }
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
