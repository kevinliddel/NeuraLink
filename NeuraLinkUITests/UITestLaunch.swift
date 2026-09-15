//
//  UITestLaunch.swift
//  NeuraLinkUITests
//
//  Shared launch configuration for the UI tests.
//
//  Created by Dedicatus on 15/09/2026.
//

import XCTest

extension XCUIApplication {

    /// Switches every UI test launches with.
    ///
    /// These are plain `-key value` launch arguments, which land in
    /// UserDefaults' argument domain: highest priority of all domains, and
    /// volatile — nothing is written to the device, and no test-only branch
    /// is needed in the app itself.
    ///
    /// - `showEnvironment = NO` skips the first-launch download of the 3D
    ///   environment mesh (~100 MB from Hugging Face). CI erases the
    ///   simulator before every run, so otherwise each launch re-downloads it
    ///   and the loading screen still owns the screen when the assertions
    ///   time out.
    /// - `tutorial.completedVersion` is set past any shipped
    ///   `TutorialScript.version`, so the onboarding tour treats itself as
    ///   already seen. Its spotlight is modal and swallows touches by design,
    ///   which would otherwise block every control these tests tap.
    static let uiTestingLaunchArguments = [
        "-com.neuralink.user.showEnvironment", "NO",
        "-com.neuralink.tutorial.completedVersion", "9999"
    ]

    /// How long to wait for the app's first chrome to appear.
    ///
    /// Deliberately generous: CI erases the simulator before every run, so the
    /// first launch of a run pays for the app install, Metal shader
    /// compilation and the VRM model load before any SwiftUI chrome exists.
    /// 30 s used to cover that and no longer does — the first test in a run
    /// timed out while later ones, launching warm, passed in seconds.
    static let coldLaunchTimeout: TimeInterval = 180

    /// Launches the app configured for UI testing. Prefer this over
    /// `launch()` in every UI test.
    func launchForUITesting() {
        launchArguments += Self.uiTestingLaunchArguments
        launch()
    }
}
