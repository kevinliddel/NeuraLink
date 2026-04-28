//
//  NeuraLinkUITests.swift
//  NeuraLinkUITests
//
//  Created by Dedicatus on 14/04/2026.
//

import XCTest

final class NeuraLinkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchAndBasicUI() throws {
        let app = XCUIApplication()
        app.launch()

        // FAB toggle is the only navigation-bar button; wait 30s for cold CI simulator boot
        let fabToggle = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            fabToggle.waitForExistence(timeout: 30.0),
            "FAB toggle button should exist in navigation bar")

        // Overlay hint — present when ready or unconfigured
        let startTalking = app.staticTexts["Start talking"]
        let tapToConfigure = app.staticTexts["Tap to configure LLMs"]
        XCTAssertTrue(
            startTalking.waitForExistence(timeout: 10.0) || tapToConfigure.exists,
            "Overlay hint should be visible"
        )
    }

    @MainActor
    func testSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        // 1 — Wait for the navigation bar, then expand the FAB menu
        let fabToggle = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(fabToggle.waitForExistence(timeout: 30.0), "FAB toggle should exist")
        fabToggle.tap()

        // 2 — Settings child button appears with accessibilityLabel "Settings"
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 10.0),
            "Settings button should appear after expanding FAB")
        settingsButton.tap()

        // 3 — Settings sheet
        let settingsTitle = app.staticTexts["AI Settings"]
        XCTAssertTrue(
            settingsTitle.waitForExistence(timeout: 20.0), "AI Settings sheet should appear")

        let apiKeyField = app.secureTextFields.element(boundBy: 0)
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: 10.0), "API Key field should be visible")

        // 4 — Dismiss sheet
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 10.0) {
            doneButton.tap()
        } else {
            app.buttons.element(boundBy: 0).tap()
        }

        XCTAssertTrue(
            app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 20.0),
            "Should return to main screen"
        )
    }
}

extension XCUIApplication {
    func printHierarchy() {
        print(self.debugDescription)
    }
}
