//
//  VRMGestureHandler.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import UIKit
import SwiftUI

// MARK: - Animation Ticker (avoids retaining VRMMetalState in a CADisplayLink selector)

final class VRMAnimationTicker: NSObject {
    weak var state: VRMMetalState?
    init(state: VRMMetalState) { self.state = state }

    @objc func tick(_ link: CADisplayLink) {
        guard let state else { return }
        Task { @MainActor [state] in
            state.animationTick(link)
        }
    }
}

// MARK: - Sky Ticker (always running — keeps sky/terrain animated during model switches)

final class VRMSkyTicker: NSObject {
    weak var state: VRMMetalState?
    init(state: VRMMetalState) { self.state = state }

    @objc func tick(_ link: CADisplayLink) {
        guard let state else { return }
        Task { @MainActor [state] in
            state.skyTick(link)
        }
    }
}

// MARK: - Gesture Handler (avoids retaining VRMMetalState strongly in gesture target-action)

final class VRMGestureHandler: NSObject {
    weak var state: VRMMetalState?
    private var panRecognizer: UIPanGestureRecognizer?
    private var pinchRecognizer: UIPinchGestureRecognizer?

    init(state: VRMMetalState) { self.state = state }

    func install(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        panRecognizer = pan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        pinchRecognizer = pinch
    }

    func invalidate(from view: UIView) {
        if let pan = panRecognizer { view.removeGestureRecognizer(pan) }
        if let pinch = pinchRecognizer { view.removeGestureRecognizer(pinch) }
        panRecognizer = nil
        pinchRecognizer = nil
    }

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let state, let view = gr.view else { return }
        let t = gr.translation(in: view)
        gr.setTranslation(.zero, in: view)
        MainActor.assumeIsolated {
            state.orbitYaw -= Float(t.x) * VRMMetalState.rotateSensitivity
            state.orbitPitch -= Float(t.y) * VRMMetalState.rotateSensitivity
            state.orbitPitch = min(max(state.orbitPitch, VRMMetalState.pitchMin), VRMMetalState.pitchMax)
            state.updateOrbitalCamera()
        }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        guard let state else { return }
        let s = Float(gr.scale)
        gr.scale = 1.0
        MainActor.assumeIsolated {
            state.orbitDistance /= pow(s, VRMMetalState.zoomSensitivity)
            state.orbitDistance = min(max(state.orbitDistance, state.orbitDistanceLimits.lowerBound), state.orbitDistanceLimits.upperBound)
            state.updateOrbitalCamera()
        }
    }
}
