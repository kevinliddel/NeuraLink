//
//  RainController.swift
//  NeuraLink
//
//  Timing state machine: idle → fadingIn → active → fadingOut.

import Foundation

final class RainController {
    enum State: Equatable, Sendable { case idle, fadingIn, active, fadingOut }

    private(set) var state:     State = .idle
    private(set) var intensity: Float = 0.0

    private var stateTimer:     Float = 0
    private var idleCountdown:  Float
    private var activeDuration: Float = 0

    let fadeInDuration:  Float = 20.0
    let fadeOutDuration: Float = 30.0

    init(idleCountdown: Float = Float.random(in: 30...120)) {
        self.idleCountdown = idleCountdown
    }

    func update(deltaTime dt: Float) {
        stateTimer += dt
        switch state {
        case .idle:
            idleCountdown -= dt
            if idleCountdown <= 0 {
                state = .fadingIn
                stateTimer = 0
                activeDuration = Float.random(in: 120...300)
            }
        case .fadingIn:
            intensity = min(stateTimer / fadeInDuration, 1.0)
            if stateTimer >= fadeInDuration { state = .active; stateTimer = 0; intensity = 1 }
        case .active:
            intensity = 1.0
            if stateTimer >= activeDuration { state = .fadingOut; stateTimer = 0 }
        case .fadingOut:
            intensity = max(1.0 - stateTimer / fadeOutDuration, 0.0)
            if stateTimer >= fadeOutDuration {
                state = .idle; stateTimer = 0; intensity = 0
                idleCountdown = Float.random(in: 60...300)
            }
        }
    }

    var isIdle: Bool { state == .idle && intensity < 0.001 }
}
