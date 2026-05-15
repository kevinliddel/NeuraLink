//
//  VRMBlinkController.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation

/// Drives VRM blink expressions automatically to make the character look more human.
public final class VRMBlinkController {
    public var enabled: Bool = true
    
    private var nextBlinkTime: Float = 0
    private var timer: Float = 0
    private var blinkState: BlinkState = .idle
    private var currentWeight: Float = 0
    
    private enum BlinkState {
        case idle
        case closing
        case opening
    }
    
    private let closeSpeed: Float = 15.0
    private let openSpeed: Float = 10.0
    
    public init() {
        scheduleNextBlink()
    }
    
    private func scheduleNextBlink() {
        nextBlinkTime = Float.random(in: 2.0...5.0)
        timer = 0
    }
    
    public func update(deltaTime: Float) {
        guard enabled else {
            if currentWeight > 0 {
                currentWeight = max(0, currentWeight - openSpeed * deltaTime)
            }
            return
        }
        
        switch blinkState {
        case .idle:
            timer += deltaTime
            if timer >= nextBlinkTime {
                blinkState = .closing
            }
            currentWeight = 0
        case .closing:
            currentWeight += closeSpeed * deltaTime
            if currentWeight >= 1.0 {
                currentWeight = 1.0
                blinkState = .opening
            }
        case .opening:
            currentWeight -= openSpeed * deltaTime
            if currentWeight <= 0.0 {
                currentWeight = 0.0
                blinkState = .idle
                scheduleNextBlink()
                
                // 15% chance for a double blink
                if Float.random(in: 0...1) < 0.15 {
                    nextBlinkTime = 0.1
                }
            }
        }
    }
    
    public func apply(to controller: VRMExpressionController?) {
        guard let controller = controller else { return }
        // Only apply if we are actually blinking, so we don't overwrite animation player's 0 weight unnecessarily
        // However, we want to smoothly close and open, so we apply whenever weight > 0 or if we just finished.
        // Actually, just applying it always is fine, it overrides the animation clip's blink.
        if enabled || currentWeight > 0 {
            controller.setExpressionWeight(.blink, weight: currentWeight)
            controller.setExpressionWeight(.blinkLeft, weight: currentWeight)
            controller.setExpressionWeight(.blinkRight, weight: currentWeight)
        }
    }
}
