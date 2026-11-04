//
//  MotionStreamHold.swift
//  NeuraLink
//
//  Why no generated gesture will run right now, for the Settings card: the
//  phone is short of memory for the motion model, or it generated too
//  slowly to keep up with speech. Set by MotionStreamCoordinator, cleared
//  when the models load or a stream keeps pace again.
//  See docs/Engine/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Observation

/// Why no stream will run right now, for the Settings card: the phone is
/// short of memory for the model, or it generates too slowly to keep up.
@Observable
final class MotionStreamHold {
    static let shared = MotionStreamHold()

    enum Reason: Equatable {
        case memory(availableMB: Int)
        case pace(secondsPerWindow: Float, tier: RuntimePressureTier)
    }

    private(set) var current: Reason?

    private init() {}

    var reason: String? {
        switch current {
        case .none: return nil
        case .memory(let availableMB):
            let needed = MotionStreamCoordinator.loadHeadroomBytes / 1_048_576
            return "Paused: \(availableMB) MB of memory free, about \(needed) MB needed to load the model."
        case .pace(let seconds, let tier):
            let when = tier > .normal
                ? "while hot or in Low Power Mode; gestures resume once it is back to normal."
                : "too slow to keep up with speech. It will try again later."
            return String(format: "Paused: this phone took %.1f s to generate 2 s of motion, ", seconds) + when
        }
    }

    func set(_ reason: Reason?) {
        guard reason != current else { return }
        current = reason
    }
}
