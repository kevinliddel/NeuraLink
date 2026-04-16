//
// VRMExtensionParser+Constraints.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import simd

extension VRMExtensionParser {

    // MARK: - Node Constraint Parsing

    /// Parse or synthesize node constraints for twist bones.
    public func parseOrSynthesizeConstraints(
        gltf: GLTFDocument, humanoid: VRMHumanoid?, isVRM0: Bool
    ) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        // VRM 1.0: Parse VRMC_node_constraint from node extensions
        if !isVRM0 {
            constraints.append(contentsOf: parseVRM1Constraints(gltf: gltf))
        }

        // VRM 0.0 (or VRM 1.0 without explicit constraints): Synthesize from humanoid
        if let humanoid = humanoid, constraints.isEmpty {
            constraints.append(contentsOf: synthesizeTwistConstraints(humanoid: humanoid))
        }

        return constraints
    }

    /// Parse VRM 1.0 VRMC_node_constraint extensions from nodes.
    func parseVRM1Constraints(gltf: GLTFDocument) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        guard let nodes = gltf.nodes else { return constraints }

        for (nodeIndex, node) in nodes.enumerated() {
            guard let extensions = node.extensions,
                let constraintAnyCodable = extensions["VRMC_node_constraint"],
                let constraintExt = constraintAnyCodable.value as? [String: Any],
                let constraintDict = constraintExt["constraint"] as? [String: Any]
            else {
                continue
            }

            // Parse roll constraint
            if let rollDict = constraintDict["roll"] as? [String: Any],
                let sourceNode = rollDict["source"] as? Int
            {
                let rollAxis = parseRollAxis(rollDict["rollAxis"] as? String)
                let weight = parseFloatValue(rollDict["weight"]) ?? 0.5

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .roll(sourceNode: sourceNode, axis: rollAxis, weight: weight)
                )
                constraints.append(constraint)
            }

            // Parse aim constraint
            if let aimDict = constraintDict["aim"] as? [String: Any],
                let sourceNode = aimDict["source"] as? Int
            {
                let aimAxis = parseAimAxis(aimDict["aimAxis"] as? String)
                let weight = parseFloatValue(aimDict["weight"]) ?? 1.0

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .aim(sourceNode: sourceNode, aimAxis: aimAxis, weight: weight)
                )
                constraints.append(constraint)
            }

            // Parse rotation constraint
            if let rotationDict = constraintDict["rotation"] as? [String: Any],
                let sourceNode = rotationDict["source"] as? Int
            {
                let weight = parseFloatValue(rotationDict["weight"]) ?? 1.0

                let constraint = VRMNodeConstraint(
                    targetNode: nodeIndex,
                    constraint: .rotation(sourceNode: sourceNode, weight: weight)
                )
                constraints.append(constraint)
            }
        }

        return constraints
    }

    /// Parse roll axis from string (VRM 1.0 spec uses "X", "Y", "Z").
    func parseRollAxis(_ axisString: String?) -> SIMD3<Float> {
        switch axisString?.uppercased() {
        case "X": return SIMD3<Float>(1, 0, 0)
        case "Y": return SIMD3<Float>(0, 1, 0)
        case "Z": return SIMD3<Float>(0, 0, 1)
        default: return SIMD3<Float>(1, 0, 0)
        }
    }

    /// Parse aim axis from string.
    func parseAimAxis(_ axisString: String?) -> SIMD3<Float> {
        switch axisString?.uppercased() {
        case "POSITIVEX": return SIMD3<Float>(1, 0, 0)
        case "NEGATIVEX": return SIMD3<Float>(-1, 0, 0)
        case "POSITIVEY": return SIMD3<Float>(0, 1, 0)
        case "NEGATIVEY": return SIMD3<Float>(0, -1, 0)
        case "POSITIVEZ": return SIMD3<Float>(0, 0, 1)
        case "NEGATIVEZ": return SIMD3<Float>(0, 0, -1)
        default: return SIMD3<Float>(0, 0, 1)
        }
    }

    /// Synthesize twist constraints for VRM 0.0 models.
    ///
    /// VRM 0.0 has no explicit constraint extension.
    /// If the model has twist bones defined in the humanoid, we automatically create roll constraints with 50% weight.
    func synthesizeTwistConstraints(humanoid: VRMHumanoid) -> [VRMNodeConstraint] {
        var constraints: [VRMNodeConstraint] = []

        let twistPairs: [(parent: VRMHumanoidBone, twist: VRMHumanoidBone, axis: SIMD3<Float>)] = [
            // Upper arm twist bones (X axis is along the arm)
            (.leftUpperArm, .leftUpperArmTwist, SIMD3<Float>(1, 0, 0)),
            (.rightUpperArm, .rightUpperArmTwist, SIMD3<Float>(1, 0, 0)),
            // Lower arm twist bones
            (.leftLowerArm, .leftLowerArmTwist, SIMD3<Float>(1, 0, 0)),
            (.rightLowerArm, .rightLowerArmTwist, SIMD3<Float>(1, 0, 0)),
            // Upper leg twist bones (Y axis is along the leg in T-pose)
            (.leftUpperLeg, .leftUpperLegTwist, SIMD3<Float>(0, 1, 0)),
            (.rightUpperLeg, .rightUpperLegTwist, SIMD3<Float>(0, 1, 0)),
            // Lower leg twist bones
            (.leftLowerLeg, .leftLowerLegTwist, SIMD3<Float>(0, 1, 0)),
            (.rightLowerLeg, .rightLowerLegTwist, SIMD3<Float>(0, 1, 0)),
        ]

        for (parentBone, twistBone, axis) in twistPairs {
            if let parentNode = humanoid.getBoneNode(parentBone),
                let twistNode = humanoid.getBoneNode(twistBone)
            {
                let constraint = VRMNodeConstraint(
                    targetNode: twistNode,
                    constraint: .roll(sourceNode: parentNode, axis: axis, weight: 0.5)
                )
                constraints.append(constraint)
            }
        }

        return constraints
    }
}
