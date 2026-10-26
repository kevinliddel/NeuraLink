//
// ConstraintSolver.swift
// NeuraLink
//
// VRMC_node_constraint 1.0: roll, aim and rotation constraints, following
// the spec's pseudocode. Each computes a target local rotation from the
// destination's rest rotation and the source's motion, and the weight
// slerps from the rest rotation toward it. A constraint whose source is
// another's destination runs after it (circular ones are skipped).
//
// Created by Dedicatus on 14/04/2026.
//

import simd

public final class ConstraintSolver: @unchecked Sendable {

    public init() {}

    /// Solves `constraints` on `nodes`, whose world transforms must be
    /// current (aim reads world positions). Each destination's world
    /// transform is updated as it is solved.
    public func solve(constraints: [VRMNodeConstraint], nodes: [VRMNode]) {
        let byDestination = Dictionary(grouping: constraints.indices) { constraints[$0].targetNode }
        var finished: [Int: Bool] = [:]  // false while in progress
        func run(_ index: Int) {
            guard finished[index] == nil else { return }
            finished[index] = false
            let constraint = constraints[index]
            for dependency in byDestination[constraint.constraint.sourceNode] ?? [] where dependency != index {
                run(dependency)
            }
            apply(constraint, nodes: nodes)
            finished[index] = true
        }
        for index in constraints.indices { run(index) }
    }

    private func apply(_ constraint: VRMNodeConstraint, nodes: [VRMNode]) {
        let sourceIndex = constraint.constraint.sourceNode
        guard constraint.targetNode < nodes.count, sourceIndex < nodes.count else { return }
        let destination = nodes[constraint.targetNode]
        let source = nodes[sourceIndex]
        guard let rotation = Self.targetRotation(constraint.constraint, source: source, destination: destination) else {
            return
        }
        destination.rotation = simd_normalize(rotation)
        destination.updateLocalMatrix()
        destination.updateWorldTransform()
    }

    /// The destination's local rotation for `constraint` (nil: undefined,
    /// e.g. an aim at its own position).
    static func targetRotation(
        _ constraint: VRMNodeConstraint.ConstraintType, source: VRMNode, destination: VRMNode
    ) -> simd_quatf? {
        let destinationRest = destination.initialRotation
        let sourceDelta = source.initialRotation.inverse * source.rotation
        switch constraint {
        case .rotation(_, let weight):
            // Local-to-local copy of the source's motion from its rest.
            return simd_slerp(destinationRest, destinationRest * sourceDelta, weight)
        case .roll(_, let axis, let weight):
            // The source's motion moved into the destination's rest frame,
            // minus the swing that tilts the roll axis: the twist about it.
            let inParent = source.initialRotation * sourceDelta * source.initialRotation.inverse
            let inDestination = destinationRest.inverse * inParent * destinationRest
            let swing = fromTo(axis, inDestination.act(axis))
            return simd_slerp(destinationRest, destinationRest * swing.inverse * inDestination, weight)
        case .aim(_, let aimAxis, let weight):
            let parentWorld = destination.parent.map { worldRotation($0.worldMatrix) } ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let toSource = source.worldPosition - destination.worldPosition
            guard simd_length(toSource) > 1e-6 else { return nil }
            let fromVector = (parentWorld * destinationRest).act(aimAxis)
            let turn = fromTo(fromVector, simd_normalize(toSource))
            return simd_slerp(destinationRest, parentWorld.inverse * turn * parentWorld * destinationRest, weight)
        }
    }

    /// Shortest rotation taking `from` onto `to` (three.js setFromUnitVectors).
    static func fromTo(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf {
        let start = simd_normalize(from), end = simd_normalize(to)
        let real = simd_dot(start, end) + 1
        if real < 1e-6 {
            let axis = abs(start.x) > abs(start.z) ? SIMD3<Float>(-start.y, start.x, 0) : SIMD3<Float>(0, -start.z, start.y)
            return simd_normalize(simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 0))
        }
        let imag = simd_cross(start, end)
        return simd_normalize(simd_quatf(ix: imag.x, iy: imag.y, iz: imag.z, r: real))
    }

    private static func worldRotation(_ matrix: simd_float4x4) -> simd_quatf {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2].map {
            simd_normalize(SIMD3<Float>($0.x, $0.y, $0.z))
        }
        return simd_quatf(simd_float3x3(columns[0], columns[1], columns[2]))
    }
}

extension VRMNodeConstraint.ConstraintType {
    var sourceNode: Int {
        switch self {
        case .roll(let source, _, _), .aim(let source, _, _), .rotation(let source, _): return source
        }
    }
}
