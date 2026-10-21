//
//  DeskPresenceTests.swift
//  NeuraLinkTests
//
//  Desk presence (docs/LIVING_COMPANION.md): the arrival / away policy
//  over a fake clock, the greeting wording, the gaze mapping, and the away
//  episode's hold. Mutating calls are evaluated into lets first: the
//  `#expect` macro cannot mutate a captured `var`.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Desk presence")
struct DeskPresenceTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minutes: Double, _ seconds: Double = 0) -> Date {
        start.addingTimeInterval(minutes * 60 + seconds)
    }

    private func isGreet(_ action: DeskPresencePolicy.Action) -> Bool {
        if case .greet = action { return true }
        return false
    }

    @Test("Sitting down after a long absence greets once; a passer-by does not")
    func greeting() {
        var policy = DeskPresencePolicy()
        policy.awayAfter = 30 * 60   // keep the away loop out of this scenario
        policy.start(now: start)
        // Nobody for 12 minutes, then a face that stays.
        let still = policy.observe(facePresent: false, now: at(12))
        let seen = policy.observe(facePresent: true, now: at(12))
        let dwell1 = policy.observe(facePresent: true, now: at(12, 1))
        let arrived = policy.observe(facePresent: true, now: at(12, 3))
        #expect(still.isEmpty && seen.isEmpty && dwell1.isEmpty)
        #expect(arrived.count == 1)
        if case .greet(let absence)? = arrived.first {
            #expect(abs(absence - 12 * 60) < 1)
        } else {
            Issue.record("no greeting")
        }
        // Still there a minute later: no second greeting. A one-second
        // flicker and back: no greeting either.
        let later = policy.observe(facePresent: true, now: at(13))
        let blink = policy.observe(facePresent: false, now: at(14))
        let back = policy.observe(facePresent: true, now: at(14, 1))
        let settled = policy.observe(facePresent: true, now: at(14, 5))
        #expect(later.isEmpty && blink.isEmpty && back.isEmpty && settled.isEmpty)

        // Someone walking past (two seconds) after a long absence: nothing.
        var passing = DeskPresencePolicy()
        passing.awayAfter = 60 * 60
        passing.start(now: start)
        let glimpse = passing.observe(facePresent: true, now: at(30))
        let glimpse2 = passing.observe(facePresent: true, now: at(30, 2))
        let gone = passing.observe(facePresent: false, now: at(30, 3))
        #expect(glimpse.isEmpty && glimpse2.isEmpty && gone.isEmpty)
    }

    @Test("Nobody for the away threshold starts the away loop; a steady face ends it")
    func away() {
        var policy = DeskPresencePolicy()
        policy.start(now: start)
        _ = policy.observe(facePresent: true, now: at(0))
        _ = policy.observe(facePresent: true, now: at(0, 3))   // arrival, no absence yet → no greeting
        let left = policy.observe(facePresent: false, now: at(1))
        let soon = policy.observe(facePresent: false, now: at(9))
        let away = policy.observe(facePresent: false, now: at(11))
        let stillAway = policy.observe(facePresent: false, now: at(20))
        #expect(left.isEmpty && soon.isEmpty)
        #expect(away == [.beginAway])
        #expect(stillAway.isEmpty)                                   // only once
        // A flicker of a face does not end it; two steady seconds do, and
        // 21 minutes away earns a greeting as well.
        let flicker = policy.observe(facePresent: true, now: at(21))
        let flickerGone = policy.observe(facePresent: false, now: at(21, 1))
        let returning = policy.observe(facePresent: true, now: at(22))
        let back = policy.observe(facePresent: true, now: at(22, 3))
        #expect(flicker.isEmpty && flickerGone.isEmpty && returning.isEmpty)
        #expect(back.contains(.endAway))
        #expect(back.contains(where: isGreet))
    }

    @Test("Greeting wording scales the absence and keeps the camera out of it")
    func wording() {
        let short = DeskPresence.greetingEvent(absence: 15 * 60, timeOfDay: "morning")
        #expect(short.contains("after 15 minutes away"))
        #expect(short.contains("It's morning"))
        #expect(short.contains("don't mention the camera"))
        #expect(DeskPresence.greetingEvent(absence: 90 * 60, timeOfDay: "evening").contains("about an hour"))
        #expect(DeskPresence.greetingEvent(absence: 3 * 3_600, timeOfDay: "evening").contains("3 hours"))
    }

    @Test("The gaze point sits at the scene camera and moves with the face in the camera's own axes")
    func gaze() {
        let camera = SIMD3<Float>(0, 1.6, 2.5)
        let centre = FaceGaze.userPosition(center: CGPoint(x: 0.5, y: 0.5), cameraPosition: camera)
        #expect(centre == camera)
        let left = FaceGaze.userPosition(center: CGPoint(x: 0.25, y: 0.5), cameraPosition: camera)
        let right = FaceGaze.userPosition(center: CGPoint(x: 0.75, y: 0.5), cameraPosition: camera)
        #expect(abs(left.x + right.x) < 0.001)                                   // symmetric about the camera
        #expect(abs(abs(left.x) - FaceGaze.horizontalSpan / 4) < 0.001)
        #expect(abs(left.z - camera.z) < 0.001)                                   // sideways, not forward
        let high = FaceGaze.userPosition(center: CGPoint(x: 0.5, y: 0.0), cameraPosition: camera)
        #expect(high.y > camera.y)

        // Camera orbited to the side: the centred face still means "at the camera",
        // and "to the side" is now along the camera's own right, not world x.
        let orbited = SIMD3<Float>(2.5, 1.6, 0)
        #expect(FaceGaze.userPosition(center: CGPoint(x: 0.5, y: 0.5), cameraPosition: orbited) == orbited)
        let side = FaceGaze.userPosition(center: CGPoint(x: 0.75, y: 0.5), cameraPosition: orbited)
        #expect(abs(side.x - orbited.x) < 0.001)
        #expect(abs(abs(side.z) - FaceGaze.horizontalSpan / 4) < 0.001)
    }

    @Test("The gaze smoother swallows jitter and glides on a real move")
    func smoother() {
        var smoother = FaceGazeSmoother()
        let first = smoother.feed(CGPoint(x: 0.5, y: 0.5))
        #expect(first == CGPoint(x: 0.5, y: 0.5))
        // A few pixels of detector noise: no new target.
        let jitter1 = smoother.feed(CGPoint(x: 0.505, y: 0.497))
        let jitter2 = smoother.feed(CGPoint(x: 0.496, y: 0.503))
        #expect(jitter1 == nil && jitter2 == nil)
        #expect(smoother.emitted == CGPoint(x: 0.5, y: 0.5))
        // A real move: targets are emitted and approach the new position.
        var emitted: [CGPoint] = []
        for _ in 0..<8 {
            if let point = smoother.feed(CGPoint(x: 0.8, y: 0.5)) { emitted.append(point) }
        }
        #expect(!emitted.isEmpty)
        #expect(emitted.last.map { $0.x > 0.75 && $0.x <= 0.8 } == true)
        #expect(zip(emitted, emitted.dropFirst()).allSatisfy { $0.x < $1.x })
        smoother.reset()
        #expect(smoother.smoothed == nil && smoother.emitted == nil)
    }

    @Test("The away episode begins once, ends once, and expires at its cap")
    func episode() {
        var episode = AwayEpisodePolicy()
        let began = episode.begin()
        let beganAgain = episode.begin()
        let early = episode.tick(dt: 1)
        episode.maxHold = 2
        let crossed = episode.tick(dt: 1)
        let after = episode.tick(dt: 1)
        let ended = episode.end()
        let endedAgain = episode.end()
        #expect(began && !beganAgain)
        #expect(!early && crossed && !after)
        #expect(ended && !endedAgain)
        #expect(AwayEpisodePolicy.clipName == "relax")
    }
}
