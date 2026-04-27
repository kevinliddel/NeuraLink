//
//  AppFunctionTests.swift
//  NeuraLinkTests
//
//  Tests for AI tool schemas and the local execution logic.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("AI Function Call Tests")
struct AppFunctionTests {

    // MARK: - Tool Schema Tests

    @Test("All tools are correctly defined in schemas")
    func testToolSchemas() {
        let tools = AppFunctionTool.all
        #expect(tools.count == 6)

        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.contains(AppFunctionTool.getWeather))
        #expect(names.contains(AppFunctionTool.searchWeb))
        #expect(names.contains(AppFunctionTool.playMusic))
        #expect(names.contains(AppFunctionTool.createReminder))
        #expect(names.contains(AppFunctionTool.createNote))
        #expect(names.contains(AppFunctionTool.openApp))
    }

    @Test("Weather tool has required parameters")
    func testWeatherSchema() {
        let weatherTool = AppFunctionTool.all.first {
            ($0["name"] as? String) == AppFunctionTool.getWeather
        }
        #expect(weatherTool != nil)

        let parameters = weatherTool?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String]
        #expect(required?.contains("location") == true)
    }

    @Test("OpenApp tool has enum constraints")
    func testOpenAppSchema() {
        let openAppTool = AppFunctionTool.all.first {
            ($0["name"] as? String) == AppFunctionTool.openApp
        }
        let parameters = openAppTool?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let appProp = properties?["app"] as? [String: Any]
        let enums = appProp?["enum"] as? [String]

        #expect(enums?.contains("Maps") == true)
        #expect(enums?.contains("Settings") == true)
        #expect(enums?.count ?? 0 >= 8)
    }

    // MARK: - Executor Dispatch Tests

    @Test("Executor handles unknown functions gracefully")
    @MainActor
    func testUnknownFunction() async {
        let executor = AppFunctionExecutor.shared
        let result = await executor.execute(name: "non_existent_tool", arguments: [:])
        #expect(result.contains("Unknown function"))
    }

    @Test("Search query encoding works correctly")
    @MainActor
    func testSearchDispatch() async {
        let executor = AppFunctionExecutor.shared
        // We can't easily test UIApplication.open, but we can verify it doesn't crash
        // and returns the expected confirmation string.
        let result = await executor.execute(
            name: AppFunctionTool.searchWeb, arguments: ["query": "Swift Testing"])
        #expect(result.contains("Opened Safari"))
        #expect(result.contains("Swift Testing"))
    }

    // MARK: - Utility Tests

    @Test("String URL encoding handles special characters")
    func testUrlEncoding() {
        let query = "Ramen & Sushi @ Tokyo"
        let encoded = query.urlEncoded
        #expect(encoded.contains("%20"))  // Spaces
        #expect(encoded.contains("%26"))  // &
        #expect(encoded.contains("%40"))  // @
        #expect(!encoded.contains(" "))
    }
}
