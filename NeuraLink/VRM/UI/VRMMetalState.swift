//
//  VRMMetalState.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit
import SwiftUI
import simd

@Observable
@MainActor
final class VRMMetalState {
    let mtkView: MTKView
    var renderer: VRMRenderer?
    
    // AI Integration
    private let aiState = RealtimeChatState.shared
    
    var isModelLoaded: Bool = false
    var errorMessage: String?
    var currentModel: VRMModel?
    let isMetalAvailable: Bool

    // Animation
    private let animationPlayer = AnimationPlayer()
    private let lipSyncController = VRMLipSyncController()
    private var displayLink: CADisplayLink?
    private var lastTickTimestamp: CFTimeInterval = 0
    private var isPlayingAppear = false
    private var pendingDefaultClip: AnimationClip?
    private var firstFrameApplied = false

    // Drives fade-in of the Metal view so T-pose is never visible
    var modelAlpha: Double = 0

    // Orbit camera
    var orbitYaw: Float = 0
    var orbitPitch: Float = 0
    var orbitDistance: Float = 3
    var orbitDistanceLimits: ClosedRange<Float> = 1...10
    private var lastCameraPosition: SIMD3<Float> = [0, 1.6, 3]
    private var gestureHandler: VRMGestureHandler?
    var orbitTarget: SIMD3<Float> = [0, 1.6, 0]

    static let pitchMin: Float = -35 * .pi / 180
    static let pitchMax: Float = 60 * .pi / 180
    static let rotateSensitivity: Float = 0.005
    static let zoomSensitivity: Float = 0.9

    private static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    init() {
        guard !Self.isPreview, let device = MTLCreateSystemDefaultDevice() else {
            mtkView = MTKView(frame: .zero, device: nil)
            isMetalAvailable = false
            return
        }
        isMetalAvailable = true
        mtkView = MTKView(frame: .zero, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)

        let config = RendererConfig(strict: .off)
        renderer = VRMRenderer(device: device, config: config)
        mtkView.delegate = renderer
        mtkView.preferredFramesPerSecond = 60
    }

    func clear() {
        stopAnimationTicker()
        gestureHandler?.invalidate(from: mtkView)
        gestureHandler = nil
        isModelLoaded = false
        errorMessage = nil
        currentModel = nil
        isPlayingAppear = false
        pendingDefaultClip = nil
        firstFrameApplied = false
        modelAlpha = 0
    }

    func display(_ model: VRMModel) {
        currentModel = model
        renderer?.loadModel(model)

        // Enable gaze tracking
        renderer?.lookAtController?.enabled = true
        renderer?.lookAtController?.target = .camera

        setupCamera(for: model)
        renderer?.setup3PointLighting()
        loadAnimationSequence(for: model)
        isModelLoaded = true
    }

    // MARK: - Animation Sequence

    private static func findVRMA(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "vrma") { return url }
        guard let dir = Bundle.main.url(forResource: "Models", withExtension: nil),
              let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        return all.first {
            $0.pathExtension.lowercased() == "vrma" &&
            $0.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
        }
    }

    private func loadAnimationSequence(for model: VRMModel) {
        let appearURL  = Self.findVRMA(named: "appear")
        let defaultURL = Self.findVRMA(named: "default_state")

        guard let defaultURL else {
            vrmLog("[VRMMetalState] No default_state.vrma found — showing bind pose")
            modelAlpha = 1.0
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                if let appearURL {
                    // Load both concurrently so there is no extra delay
                    async let a = VRMAnimationLoader.loadVRMA(from: appearURL, model: model)
                    async let d = VRMAnimationLoader.loadVRMA(from: defaultURL, model: model)
                    let (appearClip, defaultClip) = try await (a, d)
                    await MainActor.run {
                        self.pendingDefaultClip = defaultClip
                        self.isPlayingAppear = true
                        self.animationPlayer.isLooping = false
                        self.animationPlayer.load(appearClip)
                        self.startAnimationTicker()
                    }
                } else {
                    let clip = try await VRMAnimationLoader.loadVRMA(from: defaultURL, model: model)
                    await MainActor.run {
                        self.animationPlayer.isLooping = true
                        self.animationPlayer.load(clip)
                        self.startAnimationTicker()
                    }
                }
            } catch {
                await MainActor.run { self.modelAlpha = 1.0 }
                vrmLog("[VRMMetalState] ⚠️ Failed to load animation: \(error)")
            }
        }
    }

    // MARK: - CADisplayLink Ticker

    private func startAnimationTicker() {
        stopAnimationTicker()
        lastTickTimestamp = 0
        let link = CADisplayLink(
            target: VRMAnimationTicker(state: self),
            selector: #selector(VRMAnimationTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimationTicker() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func animationTick(_ link: CADisplayLink) {
        guard let model = currentModel else { return }

        let now = link.timestamp
        let dt: Float
        if lastTickTimestamp == 0 {
            dt = 0
        } else {
            dt = Float(min(now - lastTickTimestamp, 1.0 / 30.0))
        }
        lastTickTimestamp = now

        // Fade in on first rendered frame — hides T-pose
        if !firstFrameApplied && dt > 0 {
            firstFrameApplied = true
            withAnimation(.easeIn(duration: 0.4)) { modelAlpha = 1.0 }
        }

        // Seamless appear → default_state transition
        if isPlayingAppear && animationPlayer.isFinished {
            isPlayingAppear = false
            if let clip = pendingDefaultClip {
                pendingDefaultClip = nil
                animationPlayer.crossfade(to: clip, duration: 0.5, from: model)
            }
        }

        animationPlayer.update(deltaTime: dt, model: model)
        animationPlayer.applyMorphWeights(to: renderer?.expressionController)

        // Update look-at tracking (eyes, head, neck)
        if let lookAt = renderer?.lookAtController {
            lookAt.cameraPosition = lastCameraPosition
            lookAt.update(deltaTime: dt)
        }
        
        // AI Lip-Sync — driven by inbound-rtp audioLevel (OpenAI audio only),
        // not by status, so mouth stays in sync through the WebRTC jitter buffer drain.
        lipSyncController.update(audioLevel: aiState.audioLevel, deltaTime: dt)
        lipSyncController.apply(to: renderer?.expressionController)
    }

    // MARK: - Camera Setup

    private func setupCamera(for model: VRMModel) {
        let bounds = model.calculateBoundingBox()
        let center = (bounds.min + bounds.max) * 0.5
        let size = bounds.max - bounds.min
        let height = max(size.y, 0.5)

        orbitTarget = SIMD3<Float>(center.x, center.y + height * 0.1, center.z)
        let halfFOV: Float = .pi / 6
        orbitDistance = (height * 0.60) / tan(halfFOV) + 0.3
        orbitDistanceLimits = (orbitDistance * 0.35)...(orbitDistance * 3.0)

        orbitYaw = 0
        orbitPitch = 0

        installGestures()
        updateOrbitalCamera()
    }

    private func installGestures() {
        gestureHandler?.invalidate(from: mtkView)
        let handler = VRMGestureHandler(state: self)
        handler.install(on: mtkView)
        gestureHandler = handler
    }

    func updateOrbitalCamera() {
        guard let renderer else { return }
        let cp = cos(orbitPitch)
        let sp = sin(orbitPitch)
        let eye = SIMD3<Float>(
            orbitTarget.x + orbitDistance * sin(orbitYaw) * cp,
            orbitTarget.y + orbitDistance * sp,
            orbitTarget.z + orbitDistance * cos(orbitYaw) * cp
        )
        lastCameraPosition = eye

        renderer.viewMatrix = OrthographicCamera.makeLookAt(
            eye: eye, target: orbitTarget, up: SIMD3<Float>(0, 1, 0)
        )
    }
}
