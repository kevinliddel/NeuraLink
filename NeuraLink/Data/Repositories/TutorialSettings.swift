//
//  TutorialSettings.swift
//  NeuraLink
//
//  Remembers whether the onboarding tour has been finished, and at which
//  version. Storage idiom follows PresenceSettings: explicit `_x` backing +
//  `access`/`withMutation`, NEVER `didSet` (under
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + @Observable, `didSet` fires
//  during init and clobbers the UserDefaults read).
//
//  Created by Dedicatus on 15/09/2026.
//

import Foundation

@Observable
final class TutorialSettings {
    static let shared = TutorialSettings()

    private static let completedVersionKey = "com.neuralink.tutorial.completedVersion"

    /// 0 = never finished a tour.
    @ObservationIgnored private var _completedVersion: Int = 0

    private init() {
        _completedVersion = UserDefaults.standard.integer(forKey: Self.completedVersionKey)
    }

    /// Highest `TutorialScript.version` the user has completed or skipped.
    var completedVersion: Int {
        get {
            access(keyPath: \.completedVersion)
            return _completedVersion
        }
        set {
            withMutation(keyPath: \.completedVersion) {
                _completedVersion = newValue
                UserDefaults.standard.set(newValue, forKey: Self.completedVersionKey)
            }
        }
    }

    /// False on a fresh install, and again after `TutorialScript.version` is
    /// bumped — which is what re-runs the tour once for existing users.
    var hasSeenCurrentTutorial: Bool {
        completedVersion >= TutorialScript.version
    }

    /// Called when the tour is finished *or* skipped — skipping is a choice,
    /// so it shouldn't nag on the next launch.
    func markSeen() {
        completedVersion = TutorialScript.version
    }

    /// Forgets the tour so it auto-starts again on the next launch. Replay
    /// from Settings starts it immediately and doesn't need this.
    func reset() {
        completedVersion = 0
    }
}
