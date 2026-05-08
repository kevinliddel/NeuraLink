//
//  VRMMetalState+Actions.swift
//  NeuraLink
//
//  Created by Dedicatus on 08/05/2026. 
// 

import MetalKit
import SwiftUI
import simd

extension VRMMetalState {
    
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

    func loadAnimationSequence(for model: VRMModel) {
        let appearURL  = Self.findVRMA(named: "appear")
        let defaultURL = Self.findVRMA(named: "neutral")

        guard let defaultURL else {
            vrmLog("[VRMMetalState] No neutral.vrma found — showing bind pose")
            renderer?.isModelVisible = true
            return
        }

        let randomPairs = Self.randomAnimNames.compactMap { name -> (String, URL)? in
            guard let url = Self.findVRMA(named: name) else { return nil }
            return (name, url)
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                // Start neutral loading immediately, run random clip loads concurrently
                async let defaultTask = VRMAnimationLoader.loadVRMA(from: defaultURL, model: model)

                var loadedEntries: [RandomAnimEntry] = []
                await withTaskGroup(of: RandomAnimEntry?.self) { group in
                    for (name, url) in randomPairs {
                        group.addTask {
                            guard let clip = try? await VRMAnimationLoader.loadVRMA(from: url, model: model) else { return nil }
                            return (name, clip)
                        }
                    }
                    for await entry in group {
                        if let entry { loadedEntries.append(entry) }
                    }
                }

                let loadedDefault = try await defaultTask

                if let appearURL {
                    let appearClip = try await VRMAnimationLoader.loadVRMA(from: appearURL, model: model)
                    await MainActor.run {
                        self.randomAnimEntries = loadedEntries
                        self.defaultClip = loadedDefault
                        self.pendingDefaultClip = loadedDefault
                        self.isPlayingAppear = true
                        self.animationPlayer.isLooping = false
                        self.animationPlayer.applyRootMotion = true
                        self.animationPlayer.load(appearClip)
                        self.startAnimationTicker()
                    }
                } else {
                    await MainActor.run {
                        self.randomAnimEntries = loadedEntries
                        self.defaultClip = loadedDefault
                        self.animationPlayer.isLooping = true
                        self.animationPlayer.load(loadedDefault)
                        self.startAnimationTicker()
                        self.scheduleNextRandomAnim()
                    }
                }
            } catch {
                await MainActor.run { self.renderer?.isModelVisible = true }
                vrmLog("[VRMMetalState] ⚠️ Failed to load animation: \(error)")
            }
        }
    }

    func scheduleNextRandomAnim() {
        randomAnimTimer = Float.random(in: Self.randomAnimIntervalRange)
    }

    // MARK: - Tick Internal Logic

    func animationTickInternal(dt: Float) {
        guard let model = currentModel else { return }

        // Reveal model on first rendered frame — hides T-pose until animation is live
        if !firstFrameApplied && dt > 0 {
            firstFrameApplied = true
            renderer?.isModelVisible = true
        }

        // Seamless appear → neutral transition
        if isPlayingAppear && animationPlayer.isFinished {
            isPlayingAppear = false
            animationPlayer.applyRootMotion = false
            if let clip = pendingDefaultClip {
                pendingDefaultClip = nil
                animationPlayer.crossfade(to: clip, duration: 0.5, from: model)
                scheduleNextRandomAnim()
            }
        }

        // Random idle animation controller
        if !isPlayingAppear {
            if isPlayingRandomAnim {
                randomAnimElapsed += dt
                if randomAnimElapsed >= randomAnimDuration {
                    isPlayingRandomAnim = false
                    randomAnimElapsed = 0
                    if let clip = defaultClip {
                        animationPlayer.crossfade(to: clip, duration: 0.5, from: model)
                    }
                    scheduleNextRandomAnim()
                    vrmLog("[RandomAnim] ↩ neutral — next random in \(String(format: "%.1f", randomAnimTimer))s")
                }
            } else if randomAnimTimer >= 0 {
                randomAnimTimer -= dt
                if randomAnimTimer <= 0, let entry = randomAnimEntries.randomElement() {
                    isPlayingRandomAnim = true
                    randomAnimElapsed = 0
                    randomAnimDuration = Float.random(in: Self.randomAnimDurationRange)
                    animationPlayer.isLooping = true
                    animationPlayer.crossfade(to: entry.clip, duration: 0.5, from: model)
                    vrmLog("[RandomAnim] ▶ '\(entry.name)' — duration: \(String(format: "%.1f", randomAnimDuration))s")
                }
            }
        }

        // Look-back: always tick state machine (advances cooldown even while animating)
        let lookBackTrigger = lookBackController.update(orbitYaw: orbitYaw, deltaTime: dt)

        // Look-back: trigger — stores peak-rotation clip, never interrupts main animation
        if let side = lookBackTrigger, !isPlayingLookBack, !isPlayingAppear {
            lookBackClip = VRMLookBackAnimationBuilder.makeClip(side: side)
            lookBackTime = 0
            isPlayingLookBack = true
        }

        // Base animation runs uninterrupted
        animationPlayer.update(deltaTime: dt, model: model)

        // Look-back slerp overlay: blend affected bones toward peak look-back pose
        if isPlayingLookBack, let lbClip = lookBackClip {
            lookBackTime += dt
            if lookBackTime >= VRMLookBackAnimationBuilder.duration {
                isPlayingLookBack = false
                lookBackClip = nil
            } else {
                let blendWeight = VRMLookBackAnimationBuilder.envelopeValue(lookBackTime)
                model.withLock {
                    for track in lbClip.jointTracks {
                        guard let humanoid = model.humanoid,
                              let nodeIndex = humanoid.getBoneNode(track.bone),
                              nodeIndex < model.nodes.count else { continue }
                        let node = model.nodes[nodeIndex]
                        // Peak rotation is constant — sample at any time (use 0)
                        if let peakRot = track.rotationSampler?(0) {
                            node.rotation = simd_slerp(node.rotation, peakRot, blendWeight)
                            node.updateLocalMatrix()
                        }
                    }
                    model.updateNodeTransforms()
                }
            }
        }

        animationPlayer.applyMorphWeights(to: renderer?.expressionController)

        // Native automatic blink animation
        blinkController.update(deltaTime: dt)
        blinkController.apply(to: renderer?.expressionController)

        // Update look-at tracking (eyes, head, neck)
        if let lookAt = renderer?.lookAtController {
            lookAt.cameraPosition = lastCameraPosition
            lookAt.update(deltaTime: dt)
        }
        
        // AI Lip-Sync — driven by inbound-rtp audioLevel (OpenAI audio only),
        // not by status, so mouth stays in sync through the WebRTC jitter buffer drain.
        lipSyncController.update(audioLevel: aiState.audioLevel, deltaTime: dt)
        lipSyncController.apply(to: renderer?.expressionController)

        // AI Emotion handling — countdown and revert to neutral
        if aiState.emotionDuration > 0 {
            aiState.emotionDuration -= dt
            if aiState.emotionDuration <= 0 {
                aiState.currentEmotion = "neutral"
                aiState.emotionDuration = 0
            }
        }

        // Update target weights only when the active emotion name changes
        let emotion = aiState.currentEmotion
        if emotion != lastAppliedEmotion {
            lastAppliedEmotion = emotion
            let profile = VRMEmotionProfile.forName(emotion)
            for preset in vrmMoodPresets {
                targetExpressionWeights[preset] = profile.weight(for: preset)
            }
            for preset in vrmBlinkEmotionPresets {
                targetExpressionWeights[preset] = profile.weight(for: preset)
            }
            // Suppress/restore auto-blink for blink-controlling emotions (e.g. wink)
            blinkController.enabled = !profile.controlsBlink
        }

        // Smooth lerp toward target weights (speed: 5x per second ~0.2 s cross-fade)
        let lerpSpeed: Float = 5.0
        let factor = min(lerpSpeed * dt, 1.0)
        for preset in vrmMoodPresets {
            let target = targetExpressionWeights[preset] ?? 0
            let current = currentExpressionWeights[preset] ?? 0
            let next = current + (target - current) * factor
            currentExpressionWeights[preset] = next
            renderer?.expressionController?.setExpressionWeight(preset, weight: next)
        }

        // Lerp blink presets when wink is active or when fading back out
        let activeProfile = VRMEmotionProfile.forName(lastAppliedEmotion)
        if activeProfile.controlsBlink || (currentExpressionWeights[.blinkLeft] ?? 0) > 0.001 {
            for preset in vrmBlinkEmotionPresets {
                let target = targetExpressionWeights[preset] ?? 0
                let current = currentExpressionWeights[preset] ?? 0
                let next = current + (target - current) * factor
                currentExpressionWeights[preset] = next
                renderer?.expressionController?.setExpressionWeight(preset, weight: next)
            }
        }
    }

    // MARK: - Camera Setup

    func setupCamera(for model: VRMModel) {
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

    func installGestures() {
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
