//
//  ConstraintSolverTests.swift
//  NeuraLinkTests
//
//  VRMC_node_constraint 1.0 on hand-built nodes: rotation copies the
//  source's motion from its rest, roll keeps only the twist about the
//  axis, aim points an axis at the source, weight slerps from rest, and a
//  constraint whose source is another's destination runs after it.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@Suite("Node constraints")
struct ConstraintSolverTests {

    private func node(_ index: Int, at position: SIMD3<Float> = .zero, rest: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) -> VRMNode {
        let node = VRMNode(index: index, name: "n\(index)", translation: position, rotation: rest, scale: [1, 1, 1])
        node.updateWorldTransform()
        return node
    }

    private func angle(_ first: simd_quatf, _ second: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(first.vector, second.vector)))) * 180 / .pi
    }

    @Test("Rotation copies the source's motion from its rest; weight 0.5 goes half way")
    func rotation() {
        let source = node(0, rest: simd_quatf(angle: 0.2, axis: [1, 0, 0]))
        let destination = node(1, rest: simd_quatf(angle: 0.4, axis: [0, 0, 1]))
        let motion = simd_quatf(angle: .pi / 3, axis: [0, 1, 0])
        source.rotation = source.initialRotation * motion
        let full = ConstraintSolver.targetRotation(.rotation(sourceNode: 0, weight: 1), source: source, destination: destination)
        #expect(full.map { angle($0, destination.initialRotation * motion) < 0.1 } == true)
        let half = ConstraintSolver.targetRotation(.rotation(sourceNode: 0, weight: 0.5), source: source, destination: destination)
        let halfway = destination.initialRotation * simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
        #expect(half.map { angle($0, halfway) < 0.1 } == true)
    }

    @Test("Roll keeps only the twist about the axis, not the swing")
    func roll() {
        let source = node(0), destination = node(1)
        let twist = simd_quatf(angle: .pi / 3, axis: [1, 0, 0])
        source.rotation = simd_quatf(angle: .pi / 6, axis: [0, 1, 0]) * twist
        let result = ConstraintSolver.targetRotation(
            .roll(sourceNode: 0, axis: [1, 0, 0], weight: 1), source: source, destination: destination)
        #expect(result.map { angle($0, twist) < 0.1 } == true, "\(String(describing: result))")
    }

    @Test("Aim turns the axis toward the source")
    func aim() {
        let source = node(0, at: [1, 0, 0]), destination = node(1)
        let result = ConstraintSolver.targetRotation(
            .aim(sourceNode: 0, aimAxis: [0, 0, 1], weight: 1), source: source, destination: destination)
        let pointed = result.map { $0.act([0, 0, 1]) }
        #expect(pointed.map { simd_distance($0, [1, 0, 0]) < 1e-4 } == true, "\(String(describing: pointed))")
    }

    @Test("A constraint driven by another constraint's destination runs after it")
    func order() {
        let driver = node(0), middle = node(1), last = node(2)
        driver.rotation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
        // Listed last-first: 2 copies 1, 1 copies 0.
        let constraints = [
            VRMNodeConstraint(targetNode: 2, constraint: .rotation(sourceNode: 1, weight: 1)),
            VRMNodeConstraint(targetNode: 1, constraint: .rotation(sourceNode: 0, weight: 1))
        ]
        ConstraintSolver().solve(constraints: constraints, nodes: [driver, middle, last])
        #expect(angle(last.rotation, driver.rotation) < 0.1)
    }
}

@Suite("Look-at range maps")
struct VRMLookAtRangesTests {

    private func lookAt() -> VRMLookAt {
        let lookAt = VRMLookAt()
        lookAt.rangeMapHorizontalOuter = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 12)
        lookAt.rangeMapHorizontalInner = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 8)
        lookAt.rangeMapVerticalDown = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 10)
        lookAt.rangeMapVerticalUp = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 6)
        return lookAt
    }

    private let degree: Float = .pi / 180

    @Test("Looking left: the left eye takes the outer map, the right eye the inner; clamped at inputMaxValue")
    func eyes() {
        let left = VRMLookAtRanges.eyeAngles(
            gazeYaw: 45 * degree, gazePitch: 0, glanceYaw: 0, isLeftEye: true, pitchDownIsPositive: true, lookAt: lookAt())
        let right = VRMLookAtRanges.eyeAngles(
            gazeYaw: 45 * degree, gazePitch: 0, glanceYaw: 0, isLeftEye: false, pitchDownIsPositive: true, lookAt: lookAt())
        #expect(abs(left.yaw - 6 * degree) < 1e-5)  // 45/90 × 12
        #expect(abs(right.yaw - 4 * degree) < 1e-5)  // 45/90 × 8
        let far = VRMLookAtRanges.eyeAngles(
            gazeYaw: 170 * degree, gazePitch: 0, glanceYaw: 0, isLeftEye: true, pitchDownIsPositive: true, lookAt: lookAt())
        #expect(abs(far.yaw - 12 * degree) < 1e-5)
    }

    @Test("Down and up use their own maps, with the pitch sign the rig uses; a glance stays inside the range")
    func pitchAndGlance() {
        let down = VRMLookAtRanges.eyeAngles(
            gazeYaw: 0, gazePitch: 45 * degree, glanceYaw: 0, isLeftEye: true, pitchDownIsPositive: true, lookAt: lookAt())
        #expect(abs(down.pitch - 5 * degree) < 1e-5)
        let up0x = VRMLookAtRanges.eyeAngles(
            gazeYaw: 0, gazePitch: 45 * degree, glanceYaw: 0, isLeftEye: true, pitchDownIsPositive: false, lookAt: lookAt())
        #expect(abs(up0x.pitch - 3 * degree) < 1e-5)
        let glance = VRMLookAtRanges.eyeAngles(
            gazeYaw: 0, gazePitch: 0, glanceYaw: 0.4, isLeftEye: true, pitchDownIsPositive: true, lookAt: lookAt())
        #expect(abs(glance.yaw - 12 * degree) < 1e-5)
    }

    @Test("Expression look-at: the side looked to gets the mapped weight, the other side 0")
    func expressions() {
        let lookAt = VRMLookAt()
        lookAt.rangeMapHorizontalOuter = VRMLookAtRangeMap(inputMaxValue: 90, outputScale: 1)
        let weights = VRMLookAtRanges.expressionWeights(
            yaw: -45 * degree, pitch: 0, pitchDownIsPositive: true, lookAt: lookAt)
        #expect(abs((weights[.lookRight] ?? 0) - 0.5) < 1e-5)
        #expect(weights[.lookLeft] == 0 && weights[.lookUp] == 0 && weights[.lookDown] == 0)
    }
}
