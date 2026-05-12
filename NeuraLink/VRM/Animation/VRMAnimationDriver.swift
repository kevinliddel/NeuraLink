//
//  VRMAnimationDriver.swift
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

import Foundation

/// A protocol representing a source of animation that can drive a VRM model.
public protocol VRMAnimationDriver {
    /// Updates the animation state and applies it to the model.
    func update(deltaTime: Float, model: VRMModel)
}

// Extension to make AnimationPlayer conform to the protocol
extension AnimationPlayer: VRMAnimationDriver {}
