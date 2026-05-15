//
// ConstraintSolver.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import simd

public final class ConstraintSolver: @unchecked Sendable {

    public init() {}

    /// Solve all constraints for the given nodes.
    public func solve(constraints: [VRMNodeConstraint], nodes: [VRMNode]) {
        for constraint in constraints {
            guard constraint.targetNode < nodes.count else { continue }

            switch constraint.constraint {
            case .roll(let sourceNode, let axis, let weight):
                guard sourceNode < nodes.count else { continue }
                solveRollConstraint(
                    source: nodes[sourceNode],
                    target: nodes[constraint.targetNode],
                    axis: axis,
                    weight: weight
                )

            case .aim:
                break

            case .rotation:
                break
            }
        }
    }

    /// Solve a roll constraint by transferring rotation around an axis.
    private func solveRollConstraint(
        source: VRMNode, target: VRMNode, axis: SIMD3<Float>, weight: Float
    ) {
        let twist = extractTwist(rotation: source.rotation, axis: axis)
        let weightedTwist = simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), twist, weight)
        target.rotation = weightedTwist
        target.updateLocalMatrix()
    }

    // MARK: - Swing-Twist Decomposition

    /// Decomposes a quaternion into swing and twist components around a given axis.
    private func extractTwist(rotation q: simd_quatf, axis: SIMD3<Float>) -> simd_quatf {
        let ra = SIMD3<Float>(q.imag.x, q.imag.y, q.imag.z)
        let p = simd_dot(ra, axis) * axis

        var twist = simd_quatf(ix: p.x, iy: p.y, iz: p.z, r: q.real)

        let lengthSquared = simd_length_squared(twist.vector)
        if lengthSquared < 1e-10 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        twist = simd_normalize(twist)

        if twist.real < 0 {
            twist = simd_quatf(
                ix: -twist.imag.x, iy: -twist.imag.y,
                iz: -twist.imag.z, r: -twist.real)
        }

        return twist
    }
}
