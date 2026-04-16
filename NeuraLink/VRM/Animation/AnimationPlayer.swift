//
// AnimationPlayer.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

public final class AnimationPlayer: @unchecked Sendable {
    // Internal lock for player state (speed, time, clip)
    private let playerLock = NSLock()

    public var speed: Float {
        get { playerLock.withLock { _speed } }
        set {
            playerLock.withLock {
                if newValue < 0 || newValue.isNaN || newValue.isInfinite {
                    _speed = 1.0
                } else {
                    _speed = newValue
                }
            }
        }
    }
    private var _speed: Float = 1.0

    public var isLooping = true
    public var applyRootMotion = false

    private var currentTime: Float = 0
    private var clip: AnimationClip?
    private var isPlaying = false
    private var currentMorphWeights: [String: Float] = [:]
    private var hasLoggedFirstFrame = false
    private let constraintSolver = ConstraintSolver()

    public init() {}

    public func load(_ clip: AnimationClip) {
        playerLock.withLock {
            self.clip = clip
            self.currentTime = 0
            self.isPlaying = true
        }
    }

    public func play() {
        playerLock.withLock { isPlaying = true }
    }

    public func pause() {
        playerLock.withLock { isPlaying = false }
    }

    public func stop() {
        playerLock.withLock {
            isPlaying = false
            currentTime = 0
        }
    }

    public func seek(to time: Float) {
        playerLock.withLock { currentTime = time }
    }

    public func update(deltaTime: Float, model: VRMModel) {
        // 1. Capture player state (thread-safe)
        let (currentClip, currentSpeed, shouldUpdate) = playerLock.withLock {
            (clip, _speed, isPlaying && clip != nil)
        }

        guard shouldUpdate, let clip = currentClip else { return }

        // 2. Lock the MODEL for the duration of the update to prevent conflicts with Renderer
        model.withLock {
            playerLock.withLock {
                currentTime += deltaTime * currentSpeed
            }
            // Use local copy of time to avoid frequent locking
            let time = playerLock.withLock { currentTime }

            let localTime: Float
            if isLooping {
                localTime = fmodf(time, clip.duration)
            } else {
                localTime = min(time, clip.duration)
                if time >= clip.duration {
                    playerLock.withLock { isPlaying = false }
                }
            }

            let debugFirstFrame = !hasLoggedFirstFrame
            var updatedCount = 0

            // 1. Process Humanoid Tracks
            for track in clip.jointTracks {
                guard let humanoid = model.humanoid,
                    let nodeIndex = humanoid.getBoneNode(track.bone),
                    nodeIndex < model.nodes.count
                else { continue }

                let node = model.nodes[nodeIndex]
                let (rotation, translation, scale) = track.sample(at: localTime)

                if let rotation = rotation {
                    node.rotation = rotation
                }
                if let translation = translation, applyRootMotion || track.bone != .hips {
                    node.translation = translation
                }
                if let scale = scale {
                    node.scale = scale
                }
                node.updateLocalMatrix()
                updatedCount += 1
            }

            // 2. Process Non-Humanoid Node Tracks (hair, accessories, etc.)
            for track in clip.nodeTracks {
                if let node = model.findNodeByNormalizedName(track.nodeNameNormalized) {
                    let (rotation, translation, scale) = track.sample(at: localTime)

                    if let rotation = rotation {
                        node.rotation = rotation
                    }
                    if let translation = translation {
                        node.translation = translation
                    }
                    if let scale = scale {
                        node.scale = scale
                    }
                    node.updateLocalMatrix()
                    updatedCount += 1

                    if debugFirstFrame {
                        vrmLogAnimation(
                            "[NON-HUMANOID] Animated '\(track.nodeName)' -> node '\(node.name ?? "unnamed")'"
                        )
                    }
                }
            }

            // 3. Process Morph Tracks
            playerLock.withLock {
                currentMorphWeights.removeAll()
                for track in clip.morphTracks {
                    let weight = track.sample(at: localTime)
                    currentMorphWeights[track.key] = weight
                }
            }

            // 4. Solve node constraints (twist bones, etc.)
            if !model.nodeConstraints.isEmpty {
                constraintSolver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
            }

            // 5. Propagate World Transforms
            model.updateNodeTransforms()

            if debugFirstFrame {
                vrmLogAnimation("[AnimationPlayer] Updated \(updatedCount) node matrices")
                hasLoggedFirstFrame = true
            }
        }
    }

    public func applyMorphWeights(to expressionController: VRMExpressionController?) {
        guard let controller = expressionController else { return }

        let weights = playerLock.withLock { currentMorphWeights }

        for (key, weight) in weights {
            if let preset = VRMExpressionPreset(rawValue: key) {
                controller.setExpressionWeight(preset, weight: weight)
            } else {
                controller.setCustomExpressionWeight(key, weight: weight)
            }
        }
    }

    public var progress: Float {
        guard let clip = playerLock.withLock({ clip }), clip.duration > 0 else { return 0 }
        let time = playerLock.withLock { currentTime }
        if isLooping {
            return fmodf(time, clip.duration) / clip.duration
        } else {
            return min(time / clip.duration, 1.0)
        }
    }

    public var isFinished: Bool {
        return playerLock.withLock {
            guard let clip = clip, !isLooping else { return false }
            return currentTime >= clip.duration
        }
    }
}
