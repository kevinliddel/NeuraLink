//
// VRMLookAtController.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - LookAt Target

public enum VRMLookAtTarget {
    case camera
    case user
    case point(SIMD3<Float>)
    case forward
}

// MARK: - LookAt Controller

public class VRMLookAtController {
    public var enabled: Bool = true
    public var mode: VRMLookAtType = .bone
    public var target: VRMLookAtTarget = .forward
    public var smoothing: Float = 0.1
    public var saccadeEnabled: Bool = true
    public var cameraPosition: SIMD3<Float> = [0, 1.6, 2.5]
    public var userPosition: SIMD3<Float> = [0, 1.6, 2.0]

    public enum State { case idle, listening, thinking, speaking }
    public var state: State = .idle

    private weak var model: VRMModel?
    private var lookAtData: VRMLookAt?
    private weak var expressionController: VRMExpressionController?

    private var leftEyeBoneIndex: Int?
    private var rightEyeBoneIndex: Int?
    private var neckBoneIndex: Int?
    private var headBoneIndex: Int?

    private var currentYaw: Float = 0
    private var currentPitch: Float = 0
    private var targetYaw: Float = 0
    private var targetPitch: Float = 0

    private var saccadeTimer: Float = 0
    private var nextSaccadeTime: Float = 2.0
    private var saccadeOffset = SIMD2<Float>(0, 0)

    public init() {}

    // MARK: - Setup

    public func setup(model: VRMModel, expressionController: VRMExpressionController? = nil) {
        self.model = model
        self.lookAtData = model.lookAt
        self.expressionController = expressionController

        if let humanoid = model.humanoid {
            leftEyeBoneIndex = humanoid.humanBones[.leftEye]?.node
            rightEyeBoneIndex = humanoid.humanBones[.rightEye]?.node
            headBoneIndex = humanoid.humanBones[.head]?.node
            neckBoneIndex = humanoid.humanBones[.neck]?.node
        }

        // Choose mode: prefer expressions if LookAt expressions with binds are available.
        var eyesHaveExpressions = false
        if let expressions = model.expressions {
            let lookAtKeys = ["LookLeft", "LookRight", "LookUp", "LookDown"]
            eyesHaveExpressions = lookAtKeys.contains {
                expressions.custom[$0].map { !$0.morphTargetBinds.isEmpty } ?? false
            }
        }

        if eyesHaveExpressions {
            mode = .expression
        } else if lookAtData?.type == .expression
            || (leftEyeBoneIndex == nil && rightEyeBoneIndex == nil)
        {
            mode = .expression
        } else {
            mode = .bone
        }
    }

    // MARK: - Update

    public func update(deltaTime: Float) {
        guard enabled, model != nil else { return }

        updateTargetAngles()
        if saccadeEnabled { updateSaccades(deltaTime: deltaTime) }

        // Frame-rate independent smoothing.
        let factor = 1.0 - pow(smoothing, deltaTime * 60.0)
        currentYaw = lerp(currentYaw, targetYaw + saccadeOffset.x, factor)
        currentPitch = lerp(currentPitch, targetPitch + saccadeOffset.y, factor)

        applyConstraints()

        if mode == .bone {
            applyToBones()
        } else {
            applyToExpressions()
        }
    }

    // MARK: - Public API

    public func lookAt(_ target: VRMLookAtTarget, duration: Float? = nil) {
        self.target = target
    }

    public func reset() {
        target = .forward
        currentYaw = 0
        currentPitch = 0
        targetYaw = 0
        targetPitch = 0
        saccadeOffset = .zero
    }

    // MARK: - Target Calculation

    private func updateTargetAngles() {
        guard let model = model else { return }

        let targetPos: SIMD3<Float>
        switch target {
        case .camera: targetPos = cameraPosition
        case .user: targetPos = userPosition
        case .point(let pos): targetPos = pos
        case .forward:
            targetYaw = 0
            targetPitch = 0
            return
        }

        var eyePosition = SIMD3<Float>(0, 1.5, 0)
        if let headIndex = headBoneIndex, headIndex < model.nodes.count {
            let head = model.nodes[headIndex]
            eyePosition = SIMD3<Float>(
                head.worldMatrix[3][0], head.worldMatrix[3][1], head.worldMatrix[3][2])
            if let lookAt = lookAtData { eyePosition += lookAt.offsetFromHeadBone }
        }

        let worldDirection = normalize(targetPos - eyePosition)

        var direction = worldDirection
        
        // Find a representative root or parent-less node to determine model facing
        let referenceNode = model.nodes.first(where: { $0.parent == nil }) ?? model.nodes.first
        if let referenceNode {
            var modelRotation = simd_quatf(referenceNode.worldMatrix)
            
            // Critical sync with VRMRenderer+Interface logic:
            // VRM 1.0 models are rotated 180 in the shader to face +Z
            if model.specVersion == .v1_0 {
                modelRotation *= simd_quatf(angle: .pi, axis: [0, 1, 0])
            }
            
            direction = modelRotation.inverse.act(worldDirection)
        }

        // Clamp target angles to biological limits (prevents eyes from looking through the head)
        let limitYaw: Float = 75 * (.pi / 180)  // 75 degrees max side-to-side
        let limitPitch: Float = 35 * (.pi / 180) // 35 degrees max up/down

        if model.specVersion == .v1_0 {
            // VRM 1.0 faces -Z locally. We treat -Z as the forward baseline.
            targetYaw = clamp(atan2(-direction.x, -direction.z), min: -limitYaw, max: limitYaw)
            targetPitch = clamp(asin(clamp(direction.y, min: -1, max: 1)), min: -limitPitch, max: limitPitch)
        } else {
            // VRM 0.x faces +Z locally.
            targetYaw = clamp(atan2(direction.x, direction.z), min: -limitYaw, max: limitYaw)
            targetPitch = clamp(asin(clamp(direction.y, min: -1, max: 1)), min: -limitPitch, max: limitPitch)
        }

        switch state {
        case .thinking:
            targetPitch += 0.2
            targetYaw *= 0.5
        case .speaking:
            targetYaw *= 0.9
            targetPitch *= 0.9
        case .listening:
            targetYaw *= 0.7
            targetPitch *= 0.7
        case .idle:
            break
        }
    }

    // MARK: - Constraints

    private func applyConstraints() {
        guard let lookAt = lookAtData else { return }

        let deg: Float = .pi / 180
        if currentYaw > 0 {
            currentYaw = min(currentYaw, lookAt.rangeMapHorizontalOuter.inputMaxValue * deg)
        } else {
            currentYaw = max(currentYaw, -lookAt.rangeMapHorizontalInner.inputMaxValue * deg)
        }
        if currentPitch > 0 {
            currentPitch = min(currentPitch, lookAt.rangeMapVerticalUp.inputMaxValue * deg)
        } else {
            currentPitch = max(currentPitch, -lookAt.rangeMapVerticalDown.inputMaxValue * deg)
        }
    }

    // MARK: - Bone Application

    private func applyToBones() {
        guard let model = model else { return }

        // Distribution coefficients:
        // Neck: 20%, Head: 50%, Eyes: 30%
        let neckWeight: Float = 0.20
        let headWeight: Float = 0.50
        let eyeWeight: Float = 0.30

        // Clamps for head/neck (eyes are secondary to head movement)
        let neckLimitYaw: Float = 25 * (.pi / 180)
        let headLimitYaw: Float = 60 * (.pi / 180)
        let headLimitPitch: Float = 40 * (.pi / 180)

        // Apply to Neck
        if let neckIndex = neckBoneIndex, neckIndex < model.nodes.count {
            let neck = model.nodes[neckIndex]
            let yaw = clamp(currentYaw * neckWeight, min: -neckLimitYaw, max: neckLimitYaw)
            let pitch = currentPitch * neckWeight * 0.5 // Minimal vertical neck movement
            neck.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            neck.updateLocalMatrix()
            neck.updateWorldTransform()
        }

        // Apply to Head
        if let headIndex = headBoneIndex, headIndex < model.nodes.count {
            let head = model.nodes[headIndex]
            let yaw = clamp(currentYaw * headWeight, min: -headLimitYaw, max: headLimitYaw)
            let pitch = clamp(currentPitch * headWeight, min: -headLimitPitch, max: headLimitPitch)
            head.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            head.updateLocalMatrix()
            head.updateWorldTransform()
        }

        // Apply to Eyes (Relative to head)
        let eyeYaw = currentYaw * eyeWeight
        let eyePitch = currentPitch * eyeWeight
        let eyeRotation = simd_quatf(angle: eyeYaw, axis: [0, 1, 0]) * simd_quatf(angle: eyePitch, axis: [1, 0, 0])

        for index in [leftEyeBoneIndex, rightEyeBoneIndex].compactMap({ $0 }) {
            guard index < model.nodes.count else { continue }
            let node = model.nodes[index]
            node.rotation = eyeRotation
            node.updateLocalMatrix()
            node.updateWorldTransform()
        }

        model.updateNodeTransforms()
    }

    // MARK: - Expression Application

    private func applyToExpressions() {
        guard model != nil else { return }

        expressionController?.setCustomExpressionWeight("LookLeft", weight: 0)
        expressionController?.setCustomExpressionWeight("LookRight", weight: 0)
        expressionController?.setCustomExpressionWeight("LookUp", weight: 0)
        expressionController?.setCustomExpressionWeight("LookDown", weight: 0)

        if abs(currentYaw) > 0.02 {
            let weight = min(abs(currentYaw) / (.pi / 4), 1.0)
            let key = currentYaw > 0 ? "LookRight" : "LookLeft"
            expressionController?.setCustomExpressionWeight(key, weight: weight)
        }

        if abs(currentPitch) > 0.02 {
            let weight = min(abs(currentPitch) / (.pi / 6), 1.0)
            let key = currentPitch > 0 ? "LookUp" : "LookDown"
            expressionController?.setCustomExpressionWeight(key, weight: weight)
        }
    }

    // MARK: - Saccades

    private func updateSaccades(deltaTime: Float) {
        saccadeTimer += deltaTime
        if saccadeTimer >= nextSaccadeTime {
            let intensity: Float = state == .speaking ? 0.002 : 0.005
            saccadeOffset = SIMD2<Float>(
                Float.random(in: -intensity...intensity),
                Float.random(in: -intensity...intensity))
            saccadeTimer = 0
            nextSaccadeTime = Float.random(in: 0.1...0.5) * (state == .speaking ? 2 : 1)
        } else {
            saccadeOffset *= 0.95
        }
    }

    // MARK: - Utilities

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }
}
