//
//  BirdInstance.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import simd

/// CPU-side state for one bird. Updated each frame by BirdBehavior, then
/// uploaded to the GPU instance buffer by BirdRenderer.
struct BirdInstance {

    // MARK: - Orbit parameters

    var orbitCenterX: Float
    var orbitCenterZ: Float
    var orbitRadiusX: Float      // ellipse semi-axis along X
    var orbitRadiusZ: Float      // ellipse semi-axis along Z
    var baseHeight: Float        // nominal Y position in world space
    var heightAmplitude: Float   // vertical oscillation amplitude (metres)
    var heightPhase: Float       // phase offset for vertical oscillation

    // MARK: - Motion state

    var orbitAngle: Float        // current angle (radians)
    var orbitSpeed: Float        // radians/s — positive = CCW from above, negative = CW
    var wingPhase: Float         // phase offset for wing-flap cycle
    var flapFrequency: Float     // wing flaps per second

    // MARK: - Appearance

    var scale: Float             // uniform scale applied to object-space geometry

    // MARK: - Derived (written by BirdBehavior, read by BirdRenderer)

    var worldPosition: SIMD3<Float> = .zero
    var yaw: Float = 0
    var wingAngle: Float = 0
}
