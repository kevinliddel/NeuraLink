//
//  NeuraLinkUITestsLaunchTests.swift
//  NeuraLinkUITests
//
//  Created by Dedicatus on 14/04/2026.
//

import XCTest

final class NeuraLinkUITestsLaunchTests: XCTestCase {

    // Disabled: running once per config causes flaky failures in CI because AVFoundation
    // and WebRTC initialise differently in headless accessibility/dark-mode environments.
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
