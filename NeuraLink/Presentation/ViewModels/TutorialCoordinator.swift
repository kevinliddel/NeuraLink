//
//  TutorialCoordinator.swift
//  NeuraLink
//
//  Drives the game-style onboarding tour: which beat is on screen, how the
//  host UI must be posed for that beat's target to exist, and when the tour
//  is considered seen.
//
//  Created by Dedicatus on 15/09/2026.
//

import Foundation
import SwiftUI

@Observable
final class TutorialCoordinator {
    static let shared = TutorialCoordinator()

    /// Delay before the first-launch tour appears, so the reveal animation of
    /// the scene finishes first.
    private static let autoStartDelay: Duration = .milliseconds(900)
    /// Delay used when replaying from Settings — long enough for the settings
    /// sheet to finish dismissing, or the overlay would be hidden behind it.
    private static let replayDelay: Duration = .milliseconds(450)

    @ObservationIgnored private var _isActive = false
    @ObservationIgnored private var _stepIndex = 0
    /// One auto-start attempt per app run, regardless of how many times the
    /// readiness signal fires.
    @ObservationIgnored private var didAttemptAutoStart = false
    @ObservationIgnored private var pendingStart: Task<Void, Never>?

    private init() {}

    // MARK: - Observable state

    private(set) var isActive: Bool {
        get {
            access(keyPath: \.isActive)
            return _isActive
        }
        set {
            withMutation(keyPath: \.isActive) { _isActive = newValue }
        }
    }

    private(set) var stepIndex: Int {
        get {
            access(keyPath: \.stepIndex)
            return _stepIndex
        }
        set {
            withMutation(keyPath: \.stepIndex) { _stepIndex = newValue }
        }
    }

    /// The beat currently on screen, or nil when the tour isn't running.
    var step: TutorialStep? {
        guard isActive, TutorialScript.steps.indices.contains(stepIndex) else { return nil }
        return TutorialScript.steps[stepIndex]
    }

    /// How the host must pose its FAB menu right now: whatever the step asks
    /// for, but never less than what its target needs to be on screen.
    var menuState: TutorialStep.MenuState {
        guard let step else { return .collapsed }
        guard let required = step.anchor?.requiredMenu else { return step.menu }
        return step.menu.rank >= required.rank ? step.menu : required
    }

    var stepCount: Int { TutorialScript.steps.count }
    var isFirstStep: Bool { stepIndex == 0 }
    var isLastStep: Bool { stepIndex >= stepCount - 1 }

    // MARK: - Lifecycle

    /// First-launch entry point. Safe to call repeatedly: it starts at most
    /// one tour per app run, and only when the tour hasn't been seen.
    func startIfNeeded() {
        guard !didAttemptAutoStart, !isActive else { return }
        guard !TutorialSettings.shared.hasSeenCurrentTutorial else { return }
        guard !RealtimeChatState.shared.isUIHidden else { return }
        didAttemptAutoStart = true
        scheduleStart(after: Self.autoStartDelay)
    }

    /// Replays the tour from Settings. The caller dismisses its sheet; the
    /// short delay lets that finish before the overlay appears.
    func replay() {
        guard !isActive else { return }
        scheduleStart(after: Self.replayDelay)
    }

    /// Starts immediately, from the top.
    func start() {
        pendingStart?.cancel()
        pendingStart = nil
        stepIndex = 0
        isActive = true
        nlLog("[Tutorial] Started — \(stepCount) steps, v\(TutorialScript.version)", level: .info)
    }

    func advance() {
        guard isActive else { return }
        if isLastStep {
            finish(skipped: false)
        } else {
            stepIndex += 1
        }
    }

    func rewind() {
        guard isActive, !isFirstStep else { return }
        stepIndex -= 1
    }

    func skip() {
        guard isActive else { return }
        finish(skipped: true)
    }

    // MARK: - Internals

    private func scheduleStart(after delay: Duration) {
        pendingStart?.cancel()
        pendingStart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.start()
        }
    }

    private func finish(skipped: Bool) {
        isActive = false
        stepIndex = 0
        TutorialSettings.shared.markSeen()
        nlLog("[Tutorial] \(skipped ? "Skipped" : "Completed") at v\(TutorialScript.version)", level: .info)
    }
}
