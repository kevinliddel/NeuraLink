//
//  DeskPresence.swift
//  NeuraLink
//
//  The desk-pod behaviours from Companion Evolution section 3
//  (docs/LIVING_COMPANION.md): greet the user when they sit down after a
//  while away, go "away" (a resting loop) when nobody has been there for a
//  while, and come back when they return. Pure policy over "is a face in
//  front of the phone right now"; the camera and Vision live in
//  Data/Vision. Also the gaze mapping from a face position to a look-at point.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation
import simd

/// Decides from a stream of present / absent observations what to do.
nonisolated struct DeskPresencePolicy: Equatable {
    /// Being away at least this long makes the next arrival worth a greeting.
    var greetAfterAbsence: TimeInterval = 10 * 60
    /// A face must stay this long before it counts as an arrival (no greeting
    /// for someone walking past).
    var arrivalDwell: TimeInterval = 3
    /// Nobody for this long → the away loop.
    var awayAfter: TimeInterval = 10 * 60
    /// A face must stay this long to end the away loop (detector flicker).
    var returnDwell: TimeInterval = 2

    private(set) var presentSince: Date?
    private(set) var absentSince: Date?
    private(set) var isAway = false
    private(set) var greetedThisArrival = false

    enum Action: Equatable {
        case greet(absence: TimeInterval)
        case beginAway
        case endAway
    }

    /// Nobody has been seen yet: absence runs from here.
    mutating func start(now: Date) {
        presentSince = nil
        absentSince = now
        isAway = false
        greetedThisArrival = false
    }

    mutating func observe(facePresent: Bool, now: Date) -> [Action] {
        var actions: [Action] = []
        if facePresent {
            let since = presentSince ?? now
            presentSince = since
            let dwell = now.timeIntervalSince(since)
            if isAway, dwell >= returnDwell {
                isAway = false
                actions.append(.endAway)
            }
            if !greetedThisArrival, dwell >= arrivalDwell {
                greetedThisArrival = true
                if let absentSince {
                    // The absence ended when the face appeared, not when the dwell was met.
                    let absence = since.timeIntervalSince(absentSince)
                    if absence >= greetAfterAbsence { actions.append(.greet(absence: absence)) }
                }
                absentSince = nil
            }
        } else {
            if absentSince == nil { absentSince = now }
            presentSince = nil
            greetedThisArrival = false
            if let absentSince, !isAway, now.timeIntervalSince(absentSince) >= awayAfter {
                isAway = true
                actions.append(.beginAway)
            }
        }
        return actions
    }
}

enum DeskPresence {

    /// The arrival greeting, injected like the other proactive events.
    nonisolated static func greetingEvent(absence: TimeInterval, timeOfDay: String) -> String {
        let away: String
        if absence >= 2 * 3_600 {
            away = "\(Int(absence / 3_600)) hours"
        } else if absence >= 3_600 {
            away = "about an hour"
        } else {
            away = "\(max(1, Int(absence / 60))) minutes"
        }
        return "*The user just sat down at the desk after \(away) away. It's \(timeOfDay). "
            + "Greet them in character with ONE warm line — glad they're back, maybe ask if they're ready to "
            + "focus — nothing more, and don't mention the camera.*"
    }
}

/// Where the user is, for the look-at, from where their face is in the
/// camera frame. The user holds the phone, so they are where the scene
/// camera is: the face's offset in the frame moves the point around the
/// camera, in the camera's own right and up directions. A fixed point in
/// world space would be "straight ahead of her", which, with the camera
/// orbited to one side, is away from the user.
enum FaceGaze {
    /// Metres the user can be off-centre at the look-at distance.
    static let horizontalSpan: Float = 1.2
    static let verticalSpan: Float = 0.9
    /// The front frame is stood up mirrored (`.leftMirrored`), like the
    /// preview: the user moving to their right moves right in the image.
    /// Flip here if she looks the wrong way on the device.
    static let mirrorX = false
    /// What the scene camera looks at, roughly her chest; defines its forward.
    static let sceneFocus: SIMD3<Float> = [0, 1.3, 0]
    /// Look-at smoothing while following a face (the controller's default,
    /// 0.1, reaches a new target in two frames — fine for a target that
    /// never moves, a twitch for one refreshed from a camera). Higher is
    /// slower: 0.85 glides over about a third of a second.
    static let followSmoothing: Float = 0.85

    /// `center` is normalised in the upright image, origin top-left.
    static func userPosition(center: CGPoint, cameraPosition: SIMD3<Float>) -> SIMD3<Float> {
        let dx = (Float(center.x) - 0.5) * horizontalSpan * (mirrorX ? -1 : 1)
        let dy = (0.5 - Float(center.y)) * verticalSpan
        var forward = sceneFocus - cameraPosition
        forward.y = 0
        let length = simd_length(forward)
        guard length > 0.001 else { return cameraPosition + [dx, dy, 0] }
        forward /= length
        // Camera's right: forward × up, the viewer's own right-hand side.
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        return cameraPosition + right * dx + SIMD3<Float>(0, dy, 0)
    }
}

/// Takes the jitter out of the detector's face position before it reaches
/// the look-at: an exponential average, and a dead zone so detection noise
/// of a few pixels produces no new target at all. Only a real move does.
struct FaceGazeSmoother: Equatable {
    /// Weight of the newest sample (0…1); lower is calmer.
    var alpha: Float = 0.35
    /// Smallest change of the averaged point (normalised frame units) worth
    /// moving the eyes for.
    var deadZone: Float = 0.02

    private(set) var smoothed: CGPoint?
    private(set) var emitted: CGPoint?

    /// Feeds one raw sample; returns a new target only when it is worth it.
    mutating func feed(_ raw: CGPoint) -> CGPoint? {
        let next: CGPoint
        if let smoothed {
            let a = CGFloat(alpha)
            next = CGPoint(x: smoothed.x + (raw.x - smoothed.x) * a, y: smoothed.y + (raw.y - smoothed.y) * a)
        } else {
            next = raw
        }
        smoothed = next
        guard let emitted else {
            self.emitted = next
            return next
        }
        let dx = Float(next.x - emitted.x), dy = Float(next.y - emitted.y)
        guard (dx * dx + dy * dy).squareRoot() >= deadZone else { return nil }
        self.emitted = next
        return next
    }

    mutating func reset() {
        smoothed = nil
        emitted = nil
    }
}
