//
//  NeuraLinkUITests.swift
//  NeuraLinkUITests
//
//  Created by Dedicatus on 14/04/2026.
//

import XCTest

final class NeuraLinkUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    @MainActor
    func testAppLaunchAndBasicUI() throws {
        app.launch()

        // Wait for the navigation bar Menu button; wait 30s for cold CI simulator boot
        let menuButton = app.buttons["Menu"]
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 30.0),
            "Menu toggle button should exist in navigation bar")

        // Overlay hint — present when ready, unconfigured, or preparing
        let possibleHints = [
            "Start talking",
            "Tap to configure LLMs",
            "Apple Neural Engine Ready",
            "Preparing local LLMs...",
            "Connecting..."
        ]
        
        let hintFound = possibleHints.contains { hint in
            app.staticTexts[hint].exists
        } || app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("Ready") || $0.label.contains("talking") }
        
        // If not immediately found, wait for at least one
        let exists = app.staticTexts.element(matching: NSPredicate(format: "label IN %@", possibleHints)).waitForExistence(timeout: 30.0)
        
        XCTAssertTrue(exists, "Overlay hint should be visible and match one of the expected states")
    }

    @MainActor
    func testSettingsSheet() throws {
        app.launch()

        // 1 — Wait for the navigation bar, then expand the FAB menu
        let menuButton = app.buttons["Menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 30.0), "Menu toggle should exist")
        menuButton.tap()

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
            app.buttons["Menu"].waitForExistence(timeout: 20.0),
            "Should return to main screen"
        )
    }
}

extension XCUIApplication {
    func printHierarchy() {
        print(self.debugDescription)
    }
}
