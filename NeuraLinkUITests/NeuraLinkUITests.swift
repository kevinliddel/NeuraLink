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

        // Check if navigation title is present
        let navTitle = app.navigationBars.staticTexts["NeuraLink"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 60.0), "The navigation title 'NeuraLink' should exist")

        // Try to find the settings button by image name or index
        let settingsButton = app.navigationBars.buttons.element(boundBy: 1)
        XCTAssertTrue(settingsButton.exists, "The settings button should exist in the navigation bar")
        
        // Check for the overlay hint
        let startTalking = app.staticTexts["Start talking"]
        let tapToConfigure = app.staticTexts["Tap to configure API key"]
        XCTAssertTrue(startTalking.exists || tapToConfigure.exists, "Overlay hint should be present")
    }

    @MainActor
    func testSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()
        
        let settingsButton = app.navigationBars.buttons.element(boundBy: 1)
        XCTAssertTrue(settingsButton.exists)
        settingsButton.tap()
        
        // Verify settings sheet is shown
        let settingsTitle = app.staticTexts["AI Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 30.0), "The AI Settings sheet should appear")
        
        // Using 'secureTextFields' which is the standard property
        let apiKeyField = app.secureTextFields.element(boundBy: 0)
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 5.0), "API Key secure field should be visible")
        
        // Close settings - using index if "Done" is not found by name
        let doneButton = app.buttons["Done"]
        if !doneButton.exists {
            app.buttons.element(boundBy: 0).tap()
        } else {
            doneButton.tap()
        }
        
        // Verify we are back
        XCTAssertTrue(navTitleExists(app: app), "Should be back to main screen")
    }
    
    private func navTitleExists(app: XCUIApplication) -> Bool {
        return app.navigationBars.staticTexts["NeuraLink"].waitForExistence(timeout: 20.0)
    }
}

extension XCUIApplication {
    // Utility to help debug if needed
    func printHierarchy() {
        print(self.debugDescription)
    }
}
