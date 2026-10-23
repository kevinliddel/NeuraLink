//
//  VRMPropSeat.swift
//  NeuraLink
//
//  Seats a held prop against the hand that holds it. A grip carried over from
//  another character (VRMPalm) lands in the right place on the palm, but the
//  drawn hand is not always the bones' hand: an outfit graft brings its own
//  hands (Oz in a hoodie gets slimmer ones than his gloves), and curled
//  fingers differ in thickness. So the grip is nudged against the skin that
//  is actually drawn, posed as the hand holds the prop: out of the fingers
//  until the prop's back just rests on them, turning and shifting as little
//  as it can from the grip it started from.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Metal
import simd

struct VRMPropSeat {
    /// Hand and finger skin in the hand bone's frame, in the holding pose.
    let points: [SIMD3<Float>]
    /// The prop's box in its grip frame at grip scale 1 (+Z is its back).
    let box: (min: SIMD3<Float>, max: SIMD3<Float>)

    /// Largest move and turn away from the starting grip.
    static let maxShift: Float = 0.03
    static let maxTurn: Float = 40 * .pi / 180

    /// Skin drawn by `hand` and its fingers (≥ 95% of the weight), in the
    /// hand bone's frame, in the model's current pose.
    static func handPoints(in model: VRMModel, hand: VRMHumanoidBone) -> [SIMD3<Float>] {
        guard let handIndex = model.humanoid?.getBoneNode(hand), let handNode = model.nodes[safe: handIndex] else {
            return []
        }
        let toHand = simd_inverse(handNode.worldMatrix)
        var handTree = Set<ObjectIdentifier>()
        func collect(_ node: VRMNode) {
            handTree.insert(ObjectIdentifier(node))
            for child in node.children { collect(child) }
        }
        collect(handNode)
        let propNodes = Set(model.props.flatMap { $0.nodes.map { ObjectIdentifier($0) } })

        var points: [SIMD3<Float>] = []
        for node in model.nodes {
            guard let meshIndex = node.mesh, meshIndex < model.meshes.count,
                  let skinIndex = node.skin, skinIndex < model.skins.count,
                  !propNodes.contains(ObjectIdentifier(node)) else { continue }
            let skin = model.skins[skinIndex]
            // Joint → hand frame, for the joints of the hand and its fingers.
            var toHandByJoint: [Int: simd_float4x4] = [:]
            for (index, joint) in skin.joints.enumerated()
            where handTree.contains(ObjectIdentifier(joint)) && index < skin.inverseBindMatrices.count {
                toHandByJoint[index] = toHand * joint.worldMatrix * skin.inverseBindMatrices[index]
            }
            guard !toHandByJoint.isEmpty else { continue }
            for primitive in model.meshes[meshIndex].primitives
            where !model.hiddenPrimitives.contains(ObjectIdentifier(primitive)) {
                guard let buffer = primitive.vertexBuffer else { continue }
                let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                for index in 0..<primitive.vertexCount {
                    let vertex = vertices[index]
                    var sum: Float = 0
                    var position = SIMD4<Float>.zero
                    for slot in 0..<4 {
                        let weight = vertex.weights[slot]
                        guard weight > 0 else { continue }
                        guard let matrix = toHandByJoint[Int(vertex.joints[slot])] else {
                            sum = -1
                            break
                        }
                        position += weight * (matrix * SIMD4<Float>(vertex.position, 1))
                        sum += weight
                    }
                    guard sum >= 0.95 else { continue }
                    points.append(SIMD3(position.x, position.y, position.z) / sum)
                }
            }
        }
        return points
    }

    /// The prop's box in its grip frame at grip scale 1: the first part's
    /// vertices through the file's node chain.
    static func box(of prop: VRMProp) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for part in prop.parts {
            for primitive in part.mesh.primitives {
                guard let buffer = primitive.vertexBuffer else { continue }
                let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                for index in 0..<primitive.vertexCount {
                    let point = part.chain.translation + part.chain.rotation.act(part.chain.scale * vertices[index].position)
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
            }
        }
        return low.x <= high.x ? (low, high) : nil
    }

    // MARK: - Fit

    /// How a grip sits, in millimetres (turn in degrees).
    struct Score {
        /// Skin inside the prop, summed depth: fingers through the phone.
        var depth: Float
        /// The prop's back floating off the hand behind it.
        var floating: Float
        /// The prop's bottom (+Y in the grip frame) past the lowest skin
        /// behind it: a phone sticking out under the heel of the hand.
        var overhang: Float
        /// Distance and turn from the starting grip.
        var shift: Float
        var turn: Float

        var total: Float { depth + floating * 2 + overhang + shift * 0.15 + turn * 0.1 }
    }

    func energy(_ grip: VRMPropGrip, from start: VRMPropGrip) -> Float {
        score(grip, from: start).total
    }

    func score(_ grip: VRMPropGrip, from start: VRMPropGrip) -> Score {
        let low = box.min * grip.scale
        let high = box.max * grip.scale
        // Footprint for "resting on": the middle of the back, not its rim.
        let inset = (high - low) * 0.15
        let inverse = grip.rotation.inverse
        var depth: Float = 0
        var gap = Float.infinity
        var heel = -Float.infinity
        for point in points {
            let local = inverse.act(point - grip.translation)
            let overX = local.x > low.x && local.x < high.x
            if overX, local.y > low.y, local.y < high.y, local.z > low.z, local.z < high.z {
                depth += min(local.x - low.x, high.x - local.x, local.y - low.y, high.y - local.y,
                             local.z - low.z, high.z - local.z)
            }
            guard local.z >= high.z - 0.002 else { continue }
            if overX { heel = max(heel, local.y) }
            if local.x > low.x + inset.x, local.x < high.x - inset.x,
               local.y > low.y + inset.y, local.y < high.y - inset.y {
                gap = min(gap, max(0, local.z - high.z))
            }
        }
        return Score(
            depth: depth * 1000,
            floating: gap.isFinite ? max(0, gap - 0.001) * 1000 : 30,
            overhang: heel.isFinite ? max(0, high.y - heel) * 1000 : 30,
            shift: simd_distance(grip.translation, start.translation) * 1000,
            turn: Self.angle(between: grip.rotation, and: start.rotation) * 180 / .pi)
    }

    /// `start` moved and turned (within maxShift / maxTurn, in its own
    /// frame) to the lowest energy a coordinate search finds.
    func fit(from start: VRMPropGrip) -> VRMPropGrip {
        guard !points.isEmpty else { return start }
        var best = start
        var bestEnergy = energy(start, from: start)
        var shiftStep: Float = 0.008
        var turnStep: Float = 12 * .pi / 180
        while shiftStep > 0.0004 {
            var improved = true
            while improved {
                improved = false
                for axis in 0..<6 {
                    for sign: Float in [-1, 1] {
                        var candidate = best
                        var unit = SIMD3<Float>.zero
                        unit[axis % 3] = 1
                        if axis < 3 {
                            candidate.translation += best.rotation.act(unit) * shiftStep * sign
                            guard simd_distance(candidate.translation, start.translation) <= Self.maxShift else { continue }
                        } else {
                            candidate.rotation = simd_normalize(best.rotation * simd_quatf(angle: turnStep * sign, axis: unit))
                            guard Self.angle(between: candidate.rotation, and: start.rotation) <= Self.maxTurn else { continue }
                        }
                        let candidateEnergy = energy(candidate, from: start)
                        if candidateEnergy < bestEnergy - 1e-4 {
                            best = candidate
                            bestEnergy = candidateEnergy
                            improved = true
                        }
                    }
                }
            }
            shiftStep *= 0.5
            turnStep *= 0.5
        }
        return best
    }

    private static func angle(between first: simd_quatf, and second: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(first.vector, second.vector))))
    }
}
