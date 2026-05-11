//
//  VRMRenderer+HitTest.swift
//  NeuraLink
//
//  Raycasting and hit detection for VRM models.
//

import Foundation
import simd
import UIKit

extension VRMRenderer {
    
    /// Result of a hit test interaction.
    public enum HitResult {
        case head
        case shoulder(isLeft: Bool)
        case torso
        case modelBody
        case none
        
        public var aiAction: String? {
            switch self {
            case .head: return "[USER_ACTION: Head Pat]"
            case .shoulder(let isLeft): return "[USER_ACTION: Tap \(isLeft ? "Left" : "Right") Shoulder]"
            case .torso, .modelBody: return "[USER_ACTION: Tap Torso]"
            case .none: return nil
            }
        }
    }
    
    /// Performs a raycast from the given screen point and returns the hit body part.
    public func hitTest(at point: CGPoint, viewSize: CGSize) -> HitResult {
        guard let model = model else { return .none }
        
        // Ensure world transforms are up to date for this frame
        model.withLock {
            for node in model.nodes where node.parent == nil {
                node.updateWorldTransform()
            }
        }
        
        // 1. Generate ray from screen point
        let ray = makeRay(at: point, viewSize: viewSize)
        
        // 2. Perform intersection tests against humanoid bones
        guard let humanoid = model.humanoid else { return .none }
        
        // --- Head & Neck Test ---
        // We use a slightly larger radius (0.18) and check both head and neck
        let headIndices = [humanoid.getBoneNode(.head), humanoid.getBoneNode(.neck)].compactMap { $0 }
        for idx in headIndices where idx < model.nodes.count {
            let node = model.nodes[idx]
            if intersectSphere(rayOrigin: ray.origin, rayDir: ray.direction, sphereCenter: node.worldPosition, radius: 0.18) {
                return .head
            }
        }
        
        // --- Shoulder Test ---
        if let leftShoulderIndex = humanoid.getBoneNode(.leftShoulder), leftShoulderIndex < model.nodes.count {
            let shoulderNode = model.nodes[leftShoulderIndex]
            if intersectSphere(rayOrigin: ray.origin, rayDir: ray.direction, sphereCenter: shoulderNode.worldPosition, radius: 0.15) {
                return .shoulder(isLeft: true)
            }
        }
        
        if let rightShoulderIndex = humanoid.getBoneNode(.rightShoulder), rightShoulderIndex < model.nodes.count {
            let shoulderNode = model.nodes[rightShoulderIndex]
            if intersectSphere(rayOrigin: ray.origin, rayDir: ray.direction, sphereCenter: shoulderNode.worldPosition, radius: 0.15) {
                return .shoulder(isLeft: false)
            }
        }
        
        // --- Torso Test ---
        let spineIndices = [humanoid.getBoneNode(.spine), humanoid.getBoneNode(.chest), humanoid.getBoneNode(.hips)].compactMap { $0 }
        for idx in spineIndices where idx < model.nodes.count {
            let node = model.nodes[idx]
            if intersectSphere(rayOrigin: ray.origin, rayDir: ray.direction, sphereCenter: node.worldPosition, radius: 0.3) {
                return .torso
            }
        }
        
        // --- Broad Bounding Box Fallback ---
        let bounds = model.calculateBoundingBox()
        let center = (bounds.min + bounds.max) * 0.5
        let extent = (bounds.max - bounds.min) * 0.5
        if intersectAABB(rayOrigin: ray.origin, rayDir: ray.direction, boxMin: center - extent * 1.2, boxMax: center + extent * 1.2) {
            return .modelBody
        }
        
        return .none
    }
    
    // MARK: - Raycasting Math
    
    private func makeRay(at point: CGPoint, viewSize: CGSize) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        // Normalize screen coordinates to [-1, 1]
        let x = Float((2.0 * point.x) / viewSize.width - 1.0)
        let y = Float(1.0 - (2.0 * point.y) / viewSize.height)
        
        // Invert view-projection matrix
        let invVP = simd_inverse(projectionMatrix * viewMatrix)
        
        // Near point in world space
        let nearPoint4 = invVP * SIMD4<Float>(x, y, -1.0, 1.0)
        let nearPoint = SIMD3<Float>(nearPoint4.x, nearPoint4.y, nearPoint4.z) / nearPoint4.w
        
        // Far point in world space
        let farPoint4 = invVP * SIMD4<Float>(x, y, 1.0, 1.0)
        let farPoint = SIMD3<Float>(farPoint4.x, farPoint4.y, farPoint4.z) / farPoint4.w
        
        let direction = simd_normalize(farPoint - nearPoint)
        return (origin: nearPoint, direction: direction)
    }
    
    private func intersectSphere(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>, sphereCenter: SIMD3<Float>, radius: Float) -> Bool {
        let L = sphereCenter - rayOrigin
        let tca = simd_dot(L, rayDir)
        if tca < 0 { return false }
        
        let d2 = simd_dot(L, L) - tca * tca
        let r2 = radius * radius
        if d2 > r2 { return false }
        
        return true
    }
    
    private func intersectAABB(rayOrigin: SIMD3<Float>, rayDir: SIMD3<Float>, boxMin: SIMD3<Float>, boxMax: SIMD3<Float>) -> Bool {
        let invDir = 1.0 / rayDir
        let t1 = (boxMin - rayOrigin) * invDir
        let t2 = (boxMax - rayOrigin) * invDir
        
        let tmin = simd_min(t1, t2)
        let tmax = simd_max(t1, t2)
        
        let tNear = max(max(tmin.x, tmin.y), tmin.z)
        let tFar = min(min(tmax.x, tmax.y), tmax.z)
        
        return tNear <= tFar && tFar > 0
    }
}
