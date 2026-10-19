//
//  DeskPresenceManager.swift
//  NeuraLink
//
//  Runs the desk-presence policy (docs/LIVING_COMPANION.md, Desk presence)
//  over the face detector once a second while the camera is on: the
//  arrival greeting through the shared proactive seam, and the away loop
//  through AwayEpisode. Opt-in (Autonomy → "Notice me at the desk").
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation

final class DeskPresenceManager {
    static let shared = DeskPresenceManager()

    static let tickInterval: Duration = .seconds(1)
    /// Two greetings closer than this would feel like a doorman.
    static let greetingCooldown: TimeInterval = 30 * 60

    private var policy = DeskPresencePolicy()
    private var loop: Task<Void, Never>?
    private var lastGreetingAt: Date?

    private init() {}

    func startIfEnabled() {
        guard PresenceSettings.shared.isDeskPresenceEnabled else { return }
        start()
    }

    func start() {
        guard loop == nil else { return }
        policy.start(now: Date())
        FacePresenceDetector.shared.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.tick()
            }
        }
        nlLog("[DeskPresence] started", level: .info)
    }

    func stop() {
        loop?.cancel()
        loop = nil
        FacePresenceDetector.shared.stop()
        AwayEpisode.end(reason: "desk presence off")
        nlLog("[DeskPresence] stopped", level: .info)
    }

    private func tick() {
        guard PresenceSettings.shared.isDeskPresenceEnabled else {
            stop()
            return
        }
        // Without the camera nothing can be judged; the clocks simply wait.
        guard CameraManager.shared.isActive else { return }
        policy.awayAfter = PresenceSettings.shared.deskAwayMinutes * 60
        for action in policy.observe(facePresent: FacePresenceDetector.shared.facePresent, now: Date()) {
            switch action {
            case .greet(let absence):
                greet(after: absence)
            case .beginAway:
                AwayEpisode.begin(reason: "nobody for \(Int(policy.awayAfter / 60)) min")
            case .endAway:
                AwayEpisode.end(reason: "they're back")
            }
        }
    }

    private func greet(after absence: TimeInterval) {
        if let last = lastGreetingAt, Date().timeIntervalSince(last) < Self.greetingCooldown { return }
        guard RealtimeChatState.shared.status == .ready else { return }
        let event = DeskPresence.greetingEvent(
            absence: absence,
            timeOfDay: ProactivePresenceManager.timeOfDayDescriptor(hour: Calendar.current.component(.hour, from: Date())))
        if ProactivePresenceManager.shared.engage(with: event) {
            lastGreetingAt = Date()
            nlLog("[DeskPresence] greeted after \(Int(absence / 60)) min", level: .info)
        }
    }
}
