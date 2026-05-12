//
//  VRMMetalState.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit
import SwiftUI
import simd
import Combine

@Observable
@MainActor
final class VRMMetalState {
    let mtkView: MTKView
    var renderer: VRMRenderer?
    
    // AI Integration
    let aiState = RealtimeChatState.shared
    
    var isModelLoaded: Bool = false
    var isEnvironmentReady: Bool = false
    var errorMessage: String?
    var currentModel: VRMModel?
    let isMetalAvailable: Bool

    // Sky ticker — independent of model lifecycle so clouds never freeze
    private var skyDisplayLink: CADisplayLink?
    private var lastSkyTimestamp: CFTimeInterval = 0

    // Animation
    let animationPlayer = AnimationPlayer()
    let lipSyncController = VRMLipSyncController()
    let blinkController = VRMBlinkController()
    private var displayLink: CADisplayLink?
    private var backgroundTimer: Timer?
    private var lastTickTimestamp: CFTimeInterval = 0
    private var isAppInBackground = false
    private var cancellables = Set<AnyCancellable>()
    
    // Generative Motion
    var useGenerativeMotion: Bool {
        get { OpenAISettings.shared.useGenerativeMotion }
        set { OpenAISettings.shared.useGenerativeMotion = newValue }
    }
    let neuralMotionEngine = NeuralMotionEngine()
    
    var isPlayingAppear = false
    var pendingDefaultClip: AnimationClip?
    var defaultClip: AnimationClip?
    var firstFrameApplied = false

    // AI Emotion smooth transition
    var currentExpressionWeights: [VRMExpressionPreset: Float] = [:]
    var targetExpressionWeights: [VRMExpressionPreset: Float] = [:]
    var lastAppliedEmotion: String = ""

    // Look-back behavior
    var lookBackController = VRMLookBackController()
    var isPlayingLookBack = false
    var lookBackClip: AnimationClip?
    var lookBackTime: Float = 0

    // Random idle animations
    typealias RandomAnimEntry = (name: String, clip: AnimationClip)
    var randomAnimEntries: [RandomAnimEntry] = []
    var isPlayingRandomAnim = false
    var randomAnimTimer: Float = -1
    var randomAnimElapsed: Float = 0
    var randomAnimDuration: Float = 0
    static let randomAnimNames = ["default_state", "neutral_2", "neutral_3", "neutral_4", "relax", "waiting"]
    static let randomAnimIntervalRange: ClosedRange<Float> = 8...20
    static let randomAnimDurationRange: ClosedRange<Float> = 5...12

    // Drives fade-in of the Metal view so T-pose is never visible
    var modelAlpha: Double = 0

    // Orbit camera
    var orbitYaw: Float = 0
    var orbitPitch: Float = 0
    var orbitDistance: Float = 3
    var orbitDistanceLimits: ClosedRange<Float> = 1...10
    var lastCameraPosition: SIMD3<Float> = [0, 1.6, 3]
    var gestureHandler: VRMGestureHandler?
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
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        mtkView.isOpaque = false

        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let config = RendererConfig(strict: .off)
        renderer = VRMRenderer(device: device, config: config)
        mtkView.delegate = renderer
        mtkView.preferredFramesPerSecond = 60
        startSkyTicker()
        setupBackgroundObservers()
        setupPoseObserver()
    }

    private func setupBackgroundObservers() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAppInBackground = true
            self?.updateTickersForCurrentState()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isAppInBackground = false
            self?.updateTickersForCurrentState()
        }
        
        // Observe PiP state changes using Combine
        PiPManager.shared.$isPiPActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTickersForCurrentState()
            }
            .store(in: &cancellables)
    }
    
    private func updateTickersForCurrentState() {
        if isAppInBackground && PiPManager.shared.isPiPActive {
            startBackgroundTicker()
        } else {
            stopBackgroundTicker()
        }
    }

    private func startBackgroundTicker() {
        guard backgroundTimer == nil else { return }
        // 30 FPS is enough for background PiP to save battery while remaining fluid
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.performTick()
                self.mtkView.draw() // Manually trigger Metal draw
            }
        }
    }

    private func stopBackgroundTicker() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }
    
    private func performTick() {
        // Reuse the logic from animationTick but without the CADisplayLink dependency
        let now = CACurrentMediaTime()
        let dt: Float = lastTickTimestamp == 0 ? 0 : Float(min(now - lastTickTimestamp, 1.0 / 30.0))
        lastTickTimestamp = now
        
        // We call the same tick logic used by CADisplayLink
        animationTickInternal(dt: dt)
        
        // Base animation runs uninterrupted
        if let model = currentModel {
            if useGenerativeMotion {
                neuralMotionEngine.currentEmotion = aiState.currentEmotion
                neuralMotionEngine.update(deltaTime: dt, model: model)
            } else {
                animationPlayer.update(deltaTime: dt, model: model)
            }
        }
        
        // Also tick sky/environment
        renderer?.updateSky(deltaTime: dt)
        renderer?.updateRain(deltaTime: dt)
        renderer?.applySkyLighting()
        renderer?.updateTerrain(deltaTime: dt)
    }

    func clear() {
        stopAnimationTicker()
        gestureHandler?.invalidate(from: mtkView)
        gestureHandler = nil
        isModelLoaded = false
        errorMessage = nil
        currentModel = nil
        renderer?.clearModel()
        isPlayingAppear = false
        pendingDefaultClip = nil
        defaultClip = nil
        firstFrameApplied = false
        modelAlpha = 0
        lookBackController.reset()
        isPlayingLookBack = false
        lookBackClip = nil
        lookBackTime = 0
        randomAnimEntries = []
        isPlayingRandomAnim = false
        randomAnimTimer = -1
        randomAnimElapsed = 0
        randomAnimDuration = 0
        currentExpressionWeights = [:]
        targetExpressionWeights = [:]
        lastAppliedEmotion = ""
    }

    func display(_ model: VRMModel) {
        currentModel = model
        renderer?.loadModel(model)

        // Enable spring bone physics (hair only — chest/breast filtered in writeBonesToNodes)
        renderer?.enableSpringBone = model.springBone != nil

        // Enable gaze tracking
        renderer?.lookAtController?.enabled = true
        renderer?.lookAtController?.target = .camera

        setupCamera(for: model)
        // Sky lighting overrides this every tick; kept for the very first rendered frame.
        renderer?.setup3PointLighting()
        loadAnimationSequence(for: model)
        isModelLoaded = true
        isEnvironmentReady = true
    }

    // MARK: - Tickers

    private func startSkyTicker() {
        let link = CADisplayLink(
            target: VRMSkyTicker(state: self),
            selector: #selector(VRMSkyTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        skyDisplayLink = link
    }

    func skyTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: Float = lastSkyTimestamp == 0 ? 0 : Float(min(now - lastSkyTimestamp, 1.0 / 30.0))
        lastSkyTimestamp = now
        renderer?.updateSky(deltaTime: dt)
        renderer?.updateRain(deltaTime: dt)
        renderer?.applySkyLighting()
        renderer?.updateTerrain(deltaTime: dt)
    }

    func startAnimationTicker() {
        stopAnimationTicker()
        lastTickTimestamp = 0
        let link = CADisplayLink(
            target: VRMAnimationTicker(state: self),
            selector: #selector(VRMAnimationTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopAnimationTicker() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func animationTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: Float = lastTickTimestamp == 0 ? 0 : Float(min(now - lastTickTimestamp, 1.0 / 30.0))
        lastTickTimestamp = now
        animationTickInternal(dt: dt)
    }

    // MARK: - Interaction

    func handleTouch(at point: CGPoint, in size: CGSize) {
        guard let renderer = renderer else { return }
        let result = renderer.hitTest(at: point, viewSize: size)
        
        vrmLog("[Interaction] Touch at \(point) in \(size) -> Result: \(result)")
        
        if case .none = result {
            return
        }
        
        // 1. Contextual Haptic Feedback
        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
        switch result {
        case .head: 
            feedbackStyle = .heavy // Solid pat
        case .face, .hand: 
            feedbackStyle = .medium // Sensitive touch
        default: 
            feedbackStyle = .light // Subtle tap
        }
        
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.prepare()
        generator.impactOccurred()
        
        // 2. Visual Reaction (Emotion)
        // Trigger a 'surprised' look for 1.5 seconds when touched
        self.aiState.currentEmotion = "surprised"
        self.aiState.emotionDuration = 1.5
        
        // 3. Notify AI (if enabled)
        guard let action = result.aiAction else { return }
        if OpenAISettings.shared.isEnabled {
            OpenAIRealtimeManager.shared.sendInteractionEvent(action)
        } else if OpenAISettings.shared.isLocalLLMEnabled {
            LocalLLMManager.shared.handleInteractionEvent(action)
        }
    }
}
