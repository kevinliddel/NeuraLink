//
//  SpringBoneSolver.swift
//  NeuraLink
//
//  VRM spring bones (hair, skirts, accessories), solved on the CPU in the
//  frame that draws them, joint by joint in chain order. The algorithm is
//  the VRMC_springBone one, as three-vrm and UniVRM run it:
//
//    nextTail = currentTail + (currentTail − prevTail)·(1 − drag)
//             + parentRotation·initialLocalRotation·boneAxis · stiffness·dt
//             + gravityDir · gravityPower·dt
//    nextTail = head + normalize(nextTail − head) · boneLength
//    push nextTail out of the chain's colliders, keeping the length
//    rotation = initialLocalRotation · fromTo(boneAxis, nextTail in the rest frame)
//
//  Each joint reads its parent's rotation from this same step, so a chain
//  bends from the root out with no lag. The GPU solver this replaced ran the
//  joints of a chain in parallel (a parent moved while its child read it),
//  shared its per-substep inputs between command buffers still in flight,
//  and applied results whenever a readback happened to land: a frame or more
//  late, and later still while the local LLM held the GPU. Hair vibrated.
//
//  Tails: VRM 1.0 lists every joint and the next one is its tail (the last
//  joint is only a tail). VRM 0.x simulates every node under a group root;
//  the tail is the first child, or for a leaf a virtual tail 7 cm along the
//  bone (UniVRM's). Tails live in the spring's center space when it names a
//  center node. Humanoid bones are never rotated.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import simd

final class SpringBoneSolver {

    struct Joint {
        let node: VRMNode
        let chain: Int
        let initialLocal: simd_float4x4
        let initialRotation: simd_quatf
        /// The tail at rest, in the joint's local space.
        let localTail: SIMD3<Float>
        let boneAxis: SIMD3<Float>
        let stiffness: Float
        let gravityPower: Float
        let gravityDir: SIMD3<Float>
        let dragForce: Float
        let hitRadius: Float
        /// Breast chains: largest swing from rest, radians.
        let maxSwing: Float?
        /// Tails in the chain's center space.
        var prevTail = SIMD3<Float>.zero
        var currentTail = SIMD3<Float>.zero
    }

    private struct Chain {
        let colliders: [Int]
        let center: VRMNode?
        let root: VRMNode
    }

    /// Steps per frame never exceed this (a stalled frame isn't caught up).
    static let maxStepsPerFrame = 4
    /// A chain root moving farther than this in one frame resets the tails.
    static let teleportDistance: Float = 1.0
    /// UniVRM's virtual tail for a VRM 0.x leaf.
    static let virtualTailLength: Float = 0.07
    /// Breast chains swing at most this far (they deform the chest mesh).
    static let breastSwingLimit: Float = .pi * 25 / 180
    /// Silent steps that let hair hang before its first frame is shown.
    static let warmUpSteps = 30

    private(set) var joints: [Joint] = []
    /// The model the joints were built for.
    private weak var builtModel: VRMModel?
    private var chains: [Chain] = []
    private var colliders: [VRMCollider] = []
    private var colliderNodes: [VRMNode?] = []
    private var lastRootPositions: [SIMD3<Float>] = []
    private var previousStep: Float = 1.0 / 60.0
    /// The spring-joint count of the model this was built for (a graft
    /// changes it, and the solver must be rebuilt).
    private(set) var builtJointCount = 0
    /// Tails go back to rest before the next step.
    var needsReset = false
    /// Rebuild before the next step (a new model, or a graft).
    private var needsSetUp = true

    /// Each chain's colliders, in spring order (tests).
    var chainColliders: [[Int]] { chains.map(\.colliders) }

    // MARK: - Setup

    /// Builds the joints from the model's rest pose (file transforms, not
    /// the current pose) and resets the tails on the next step.
    func setUp(model: VRMModel) {
        joints = []
        chains = []
        lastRootPositions = []
        builtModel = model
        needsSetUp = false
        builtJointCount = model.springBoneJointCount
        guard let springBone = model.springBone else { return }
        colliders = springBone.colliders
        colliderNodes = colliders.map { model.nodes[safe: $0.node] }
        let restWorld = Self.restWorldMatrices(model)
        let humanoidNodes = Set(model.humanoid?.humanBones.values.map(\.node) ?? [])
        let chestNodes = [VRMHumanoidBone.chest, .upperChest].compactMap { bone in
            model.humanoid?.humanBones[bone]?.node
        }

        for spring in springBone.springs {
            guard let root = spring.joints.first.flatMap({ model.nodes[safe: $0.node] }) else { continue }
            var chainColliders: [Int] = []
            for group in spring.colliderGroups where group < springBone.colliderGroups.count {
                for index in springBone.colliderGroups[group].colliders where index < colliders.count
                    && !chainColliders.contains(index) {
                    chainColliders.append(index)
                }
            }
            let chainIndex = chains.count
            chains.append(Chain(colliders: chainColliders, center: spring.center.flatMap { model.nodes[safe: $0] },
                                root: root))
            let maxSwing = Self.isBreastChain(root: root, model: model, chestNodes: chestNodes)
                ? Self.breastSwingLimit : nil

            for (position, settings) in spring.joints.enumerated() {
                guard let node = model.nodes[safe: settings.node], node.parent != nil,
                      !humanoidNodes.contains(settings.node),
                      let rest = restWorld[ObjectIdentifier(node)],
                      let tailWorld = Self.restTail(
                        of: node, position: position, spring: spring, model: model, restWorld: restWorld)
                else { continue }
                let local = rest.inverse * SIMD4<Float>(tailWorld, 1)
                let localTail = SIMD3<Float>(local.x, local.y, local.z)
                guard simd_length(localTail) > 1e-5 else { continue }
                let gravityDir = simd_length(settings.gravityDir) > 1e-5
                    ? simd_normalize(settings.gravityDir) : SIMD3<Float>(0, -1, 0)
                joints.append(Joint(
                    node: node, chain: chainIndex, initialLocal: Self.restLocal(node),
                    initialRotation: node.initialRotation, localTail: localTail,
                    boneAxis: simd_normalize(localTail), stiffness: settings.stiffness,
                    gravityPower: settings.gravityPower, gravityDir: gravityDir,
                    dragForce: min(max(settings.dragForce, 0), 1), hitRadius: settings.hitRadius,
                    maxSwing: maxSwing))
            }
        }
        needsReset = true
    }

    /// Where the joint's tail sits at rest, in world space.
    private static func restTail(
        of node: VRMNode, position: Int, spring: VRMSpring, model: VRMModel,
        restWorld: [ObjectIdentifier: simd_float4x4]
    ) -> SIMD3<Float>? {
        func origin(_ node: VRMNode) -> SIMD3<Float>? {
            restWorld[ObjectIdentifier(node)].map { SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
        }
        if !model.isVRM0 {
            guard position + 1 < spring.joints.count,
                  let tail = model.nodes[safe: spring.joints[position + 1].node] else { return nil }
            return origin(tail)
        }
        if let child = node.children.first { return origin(child) }
        guard let head = origin(node), let parent = node.parent, let parentHead = origin(parent),
              simd_length(head - parentHead) > 1e-5 else { return nil }
        return head + simd_normalize(head - parentHead) * virtualTailLength
    }

    private static func isBreastChain(root: VRMNode, model: VRMModel, chestNodes: [Int]) -> Bool {
        if let parent = root.parent, chestNodes.contains(where: { model.nodes[safe: $0] === parent }) {
            return true
        }
        let name = (root.name ?? "").lowercased()
        return ["bust", "breast", "boob", "boin", "mune"].contains { name.contains($0) }
    }

    /// The node's local transform from the file.
    private static func restLocal(_ node: VRMNode) -> simd_float4x4 {
        var matrix = simd_float4x4(node.initialRotation)
        matrix.columns.0 *= node.initialScale.x
        matrix.columns.1 *= node.initialScale.y
        matrix.columns.2 *= node.initialScale.z
        matrix.columns.3 = SIMD4<Float>(node.initialTranslation, 1)
        return matrix
    }

    /// Every node's world transform in the file's rest pose.
    private static func restWorldMatrices(_ model: VRMModel) -> [ObjectIdentifier: simd_float4x4] {
        var result: [ObjectIdentifier: simd_float4x4] = [:]
        func visit(_ node: VRMNode, _ parentWorld: simd_float4x4) {
            let world = parentWorld * restLocal(node)
            result[ObjectIdentifier(node)] = world
            for child in node.children { visit(child, world) }
        }
        for node in model.nodes where node.parent == nil { visit(node, matrix_identity_float4x4) }
        return result
    }

    /// The next frame rebuilds the joints and settles them first. Only the
    /// renderer that steps the springs builds them, so a second renderer
    /// drawing the same model (the portrait) never touches its hair.
    func invalidate() {
        needsSetUp = true
    }

    // MARK: - Stepping

    /// Advances `model`'s springs by one frame and poses their nodes,
    /// building and settling them first when the model or its chains changed.
    func update(model: VRMModel, deltaTime: Float) {
        if needsSetUp || builtModel !== model || builtJointCount != model.springBoneJointCount {
            setUp(model: model)
            warmUp(steps: Self.warmUpSteps)
        }
        update(deltaTime: deltaTime)
    }

    /// Advances the springs by one frame and poses their nodes.
    func update(deltaTime: Float) {
        guard !joints.isEmpty, deltaTime > 0 else { return }
        if needsReset || teleported() {
            reset()
            needsReset = false
        }
        let steps = min(Self.maxStepsPerFrame, max(1, Int((deltaTime * 60 - 0.05).rounded(.up))))
        let step = deltaTime / Float(steps)
        for _ in 0..<steps { advance(by: step) }
    }

    /// Settles the hair under gravity before the first frame is shown.
    func warmUp(steps: Int) {
        guard !joints.isEmpty else { return }
        reset()
        needsReset = false
        for _ in 0..<steps { advance(by: 1.0 / 60.0) }
        // Keep the settled shape, drop the velocity it settled with.
        for index in joints.indices { joints[index].prevTail = joints[index].currentTail }
    }

    /// Tails back to the rest pose under the current parents, at rest.
    func reset() {
        for index in joints.indices {
            let joint = joints[index]
            guard let parent = joint.node.parent else { continue }
            joint.node.localRotation = joint.initialRotation
            joint.node.updateWorldTransform()
            let tail = Self.transform(parent.worldMatrix * joint.initialLocal, joint.localTail)
            let centerTail = Self.transform(worldToCenter(joint.chain), tail)
            joints[index].prevTail = centerTail
            joints[index].currentTail = centerTail
        }
        lastRootPositions = chains.map(\.root.worldPosition)
        previousStep = 1.0 / 60.0
    }

    private func teleported() -> Bool {
        let roots = chains.map(\.root.worldPosition)
        defer { lastRootPositions = roots }
        guard roots.count == lastRootPositions.count else { return false }
        return zip(roots, lastRootPositions).contains { simd_distance($0, $1) > Self.teleportDistance }
    }

    private func worldToCenter(_ chain: Int) -> simd_float4x4 {
        chains[chain].center.map { $0.worldMatrix.inverse } ?? matrix_identity_float4x4
    }

    private func advance(by step: Float) {
        // Verlet with a changing step: the carried velocity scales with it.
        let velocityScale = min(max(step / previousStep, 0.5), 2)
        previousStep = step
        for index in joints.indices {
            advanceJoint(index, step: step, velocityScale: velocityScale)
        }
    }

    private func advanceJoint(_ index: Int, step: Float, velocityScale: Float) {
        let joint = joints[index]
        guard let parent = joint.node.parent else { return }
        let restFrame = parent.worldMatrix * joint.initialLocal
        let head = joint.node.worldPosition
        let restTail = Self.transform(restFrame, joint.localTail)
        let boneLength = simd_distance(restTail, head)
        guard boneLength > 1e-6 else { return }

        let center = chains[joint.chain].center?.worldMatrix
        let toCenter = center?.inverse ?? matrix_identity_float4x4
        let toCenterRotation = Self.rotation(of: toCenter)
        let axis = simd_normalize(toCenterRotation * simd_normalize(restTail - head))
        let gravity = simd_normalize(toCenterRotation * joint.gravityDir)

        let retain: Float = pow(1 - joint.dragForce, step * 60) * velocityScale
        let inertia: SIMD3<Float> = (joint.currentTail - joint.prevTail) * retain
        let pull: SIMD3<Float> = axis * (joint.stiffness * step) + gravity * (joint.gravityPower * step)
        let next: SIMD3<Float> = joint.currentTail + inertia + pull
        var nextWorld = center.map { Self.transform($0, next) } ?? next
        nextWorld = Self.constrain(nextWorld, head: head, length: boneLength, fallback: restTail)
        collide(&nextWorld, head: head, length: boneLength, joint: joint)

        joints[index].prevTail = joint.currentTail
        joints[index].currentTail = Self.transform(toCenter, nextWorld)

        let target = Self.transform(restFrame.inverse, nextWorld)
        guard simd_length(target) > 1e-6 else { return }
        var swing = Self.rotation(from: joint.boneAxis, to: simd_normalize(target))
        if let limit = joint.maxSwing {
            let angle = 2 * acos(min(abs(swing.real), 1))
            if angle > limit { swing = simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), swing, limit / angle) }
        }
        joint.node.localRotation = simd_normalize(joint.initialRotation * swing)
        joint.node.updateWorldTransform()
    }

    /// Pushes the tail out of every collider of the joint's chain (spec
    /// order) — or, for an inside collider, back into it — keeping the
    /// bone's length after each push.
    private func collide(_ tail: inout SIMD3<Float>, head: SIMD3<Float>, length: Float, joint: Joint) {
        for index in chains[joint.chain].colliders {
            guard let node = colliderNodes[index] else { continue }
            let matrix = node.worldMatrix
            var pushed = false
            switch colliders[index].shape {
            case .sphere(let offset, let radius):
                pushed = Self.pushOut(&tail, from: Self.transform(matrix, offset), radius: radius + joint.hitRadius)
            case .capsule(let offset, let radius, let capsuleTail):
                let axisPoint = Self.closestPoint(
                    to: tail, from: Self.transform(matrix, offset), to: Self.transform(matrix, capsuleTail))
                pushed = Self.pushOut(&tail, from: axisPoint, radius: radius + joint.hitRadius)
            case .insideSphere(let offset, let radius):
                pushed = Self.pullIn(&tail, toward: Self.transform(matrix, offset), radius: radius - joint.hitRadius)
            case .insideCapsule(let offset, let radius, let capsuleTail):
                let axisPoint = Self.closestPoint(
                    to: tail, from: Self.transform(matrix, offset), to: Self.transform(matrix, capsuleTail))
                pushed = Self.pullIn(&tail, toward: axisPoint, radius: radius - joint.hitRadius)
            case .plane(let offset, let normal):
                let point = Self.transform(matrix, offset)
                let worldNormal = Self.rotation(of: matrix) * normal
                guard simd_length(worldNormal) > 1e-6 else { continue }
                let unit = simd_normalize(worldNormal)
                let distance = simd_dot(tail - point, unit) - joint.hitRadius
                if distance < 0 {
                    tail -= unit * distance
                    pushed = true
                }
            }
            if pushed { tail = Self.constrain(tail, head: head, length: length, fallback: tail) }
        }
    }

    // MARK: - Math

    /// The point of segment start…end nearest `point` (a capsule's axis; its
    /// head and tail are both points in the collider node's space).
    private static func closestPoint(
        to point: SIMD3<Float>, from start: SIMD3<Float>, to end: SIMD3<Float>
    ) -> SIMD3<Float> {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        let along = lengthSquared > 1e-10 ? min(max(simd_dot(point - start, segment) / lengthSquared, 0), 1) : 0
        return start + segment * along
    }

    /// An inside collider (extended collider): a point farther than `radius`
    /// from `center` comes back onto that sphere.
    private static func pullIn(_ point: inout SIMD3<Float>, toward center: SIMD3<Float>, radius: Float) -> Bool {
        let delta = point - center
        let distance = simd_length(delta)
        guard radius > 0, distance > radius, distance > 1e-6 else { return false }
        point = center + delta / distance * radius
        return true
    }

    private static func pushOut(_ point: inout SIMD3<Float>, from center: SIMD3<Float>, radius: Float) -> Bool {
        let delta = point - center
        let distance = simd_length(delta)
        guard distance < radius, distance > 1e-6 else { return false }
        point = center + delta / distance * radius
        return true
    }

    private static func constrain(
        _ tail: SIMD3<Float>, head: SIMD3<Float>, length: Float, fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let delta = tail - head
        let distance = simd_length(delta)
        return distance > 1e-6 ? head + delta / distance * length : fallback
    }

    private static func transform(_ matrix: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let result = matrix * SIMD4<Float>(point, 1)
        return SIMD3(result.x, result.y, result.z)
    }

    private static func rotation(of matrix: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
    }

    /// Shortest rotation taking unit `from` onto unit `to` (three.js
    /// setFromUnitVectors: no acos, clean near identity).
    private static func rotation(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let real = simd_dot(from, to) + 1
        if real < 1e-6 {
            let axis = abs(from.x) > abs(from.z) ? SIMD3<Float>(-from.y, from.x, 0) : SIMD3<Float>(0, -from.z, from.y)
            return simd_normalize(simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 0))
        }
        let imag = simd_cross(from, to)
        return simd_normalize(simd_quatf(ix: imag.x, iy: imag.y, iz: imag.z, r: real))
    }
}
