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
        let navTitle = app.navigationBars["NeuraLink"]
        XCTAssertTrue(navTitle.exists, "The navigation title 'NeuraLink' should exist")

        // Check if settings button exists
        // SwiftUI buttons with images often have the image's name as the label
        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.exists, "The settings button (gearshape) should exist")
        
        // Check if model picker exists
        let modelPicker = app.buttons["chevron.up.chevron.down"]
        XCTAssertTrue(modelPicker.exists, "The model picker button (chevron) should exist")
    }

    @MainActor
    func testSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()
        
        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.exists)
        settingsButton.tap()
        
        // Verify settings sheet is shown
        let settingsTitle = app.staticTexts["AI Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5.0), "The AI Settings sheet should appear")
        
        // Check for specific elements in settings
        let apiKeyLabel = app.staticTexts["OpenAI API Key"]
        XCTAssertTrue(apiKeyLabel.exists, "API Key section should be visible")
        
        // Close settings
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.exists)
        doneButton.tap()
        
        // Verify we are back
        XCTAssertFalse(settingsTitle.exists, "The settings sheet should be dismissed")
    }
}
