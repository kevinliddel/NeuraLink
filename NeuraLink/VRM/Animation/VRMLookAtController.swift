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

        let direction = normalize(targetPos - eyePosition)
        targetYaw = atan2(direction.x, direction.z)
        targetPitch = asin(clamp(direction.y, min: -1, max: 1))

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

        let yawQuat = simd_quatf(angle: currentYaw * 0.5, axis: [0, 1, 0])
        let pitchQuat = simd_quatf(angle: currentPitch * 0.5, axis: [1, 0, 0])
        let rotation = yawQuat * pitchQuat

        for index in [leftEyeBoneIndex, rightEyeBoneIndex].compactMap({ $0 }) {
            guard index < model.nodes.count else { continue }
            let node = model.nodes[index]
            node.rotation = rotation
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
