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

    // Crossfade blend state. The snapshot is node poses BY INDEX of one
    // model: applied to another model it wrote the first model's bone
    // offsets into the second's skeleton (twisted bones after a character
    // switch mid-crossfade), so it is tied to the model it was taken from.
    private typealias NodePose = (rotation: simd_quatf, translation: SIMD3<Float>, scale: SIMD3<Float>)
    private var blendSnapshot: [Int: NodePose] = [:]
    private var blendModel: ObjectIdentifier?
    private var blendElapsed: Float = 0
    private var blendDuration: Float = 0
    private var isBlending = false

    public init() {}

    public func load(_ clip: AnimationClip) {
        playerLock.withLock {
            self.clip = clip
            self.currentTime = 0
            self.isPlaying = true
        }
    }

    /// Back to nothing playing: no clip, no crossfade, no morph weights.
    /// The scene calls it when its character leaves.
    public func reset() {
        playerLock.withLock {
            clip = nil
            currentTime = 0
            isPlaying = false
            isLooping = true
            applyRootMotion = false
            currentMorphWeights.removeAll()
            blendSnapshot.removeAll()
            blendModel = nil
            isBlending = false
        }
    }

    /// Smoothly blends from the current node poses to `newClip` over
    /// `duration` seconds. Only the nodes `newClip` drives blend: a node it
    /// leaves alone keeps whatever pose it has (look-at, spring bones).
    public func crossfade(to newClip: AnimationClip, duration: Float, from model: VRMModel) {
        model.withLock {
            var snapshot = [Int: NodePose]()
            for index in Self.drivenNodeIndices(of: newClip, in: model) {
                let node = model.nodes[index]
                snapshot[index] = (node.rotation, node.translation, node.scale)
            }
            playerLock.withLock {
                blendSnapshot = snapshot
                blendModel = ObjectIdentifier(model)
                blendElapsed = 0
                blendDuration = max(duration, 0.001)
                isBlending = true
                isLooping = true
                clip = newClip
                currentTime = 0
                isPlaying = true
            }
        }
    }

    /// Indices of the nodes `clip`'s tracks write on `model`.
    private static func drivenNodeIndices(of clip: AnimationClip, in model: VRMModel) -> Set<Int> {
        var indices = Set<Int>()
        for track in clip.jointTracks {
            if let index = model.humanoid?.getBoneNode(track.bone), index < model.nodes.count { indices.insert(index) }
        }
        for track in clip.nodeTracks {
            if let node = model.findNodeByNormalizedName(track.nodeNameNormalized),
               let index = model.nodes.firstIndex(where: { $0 === node }) {
                indices.insert(index)
            }
        }
        return indices
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
                        nlLogAnimation(
                            "[NON-HUMANOID] Animated '\(track.nodeName)' -> node '\(node.name ?? "unnamed")'"
                        )
                    }
                }
            }

            // 3. Crossfade blend — lerp snapshot toward new-clip pose
            let (blending, snap, elapsed, dur, snapModel) = playerLock.withLock {
                (isBlending, blendSnapshot, blendElapsed, blendDuration, blendModel)
            }
            let needsBlend = blending && snapModel == ObjectIdentifier(model)
            if blending && !needsBlend {
                // Taken from another model: never apply it here.
                playerLock.withLock {
                    isBlending = false
                    blendSnapshot.removeAll()
                }
            }
            if needsBlend {
                let raw = min(elapsed / dur, 1.0)
                let t = raw * raw * (3.0 - 2.0 * raw)  // smoothstep
                for (nodeIdx, pose) in snap {
                    guard nodeIdx < model.nodes.count else { continue }
                    let node = model.nodes[nodeIdx]
                    node.rotation = simd_slerp(pose.rotation, node.rotation, t)
                    node.translation = pose.translation + (node.translation - pose.translation) * t
                    node.scale = pose.scale + (node.scale - pose.scale) * t
                    node.updateLocalMatrix()
                }
                let newElapsed = elapsed + deltaTime
                playerLock.withLock {
                    blendElapsed = newElapsed
                    if newElapsed >= dur { isBlending = false }
                }
            }

            // 4. Process Morph Tracks
            playerLock.withLock {
                currentMorphWeights.removeAll()
                for track in clip.morphTracks {
                    let weight = track.sample(at: localTime)
                    currentMorphWeights[track.key] = weight
                }
            }

            // 5. Solve node constraints (twist bones, etc.)
            if !model.nodeConstraints.isEmpty {
                constraintSolver.solve(constraints: model.nodeConstraints, nodes: model.nodes)
            }

            // 6. Propagate World Transforms
            model.updateNodeTransforms()

            if debugFirstFrame {
                nlLogAnimation("[AnimationPlayer] Updated \(updatedCount) node matrices")
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
