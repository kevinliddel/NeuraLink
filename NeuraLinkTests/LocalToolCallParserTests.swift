//
//  LocalToolCallParserTests.swift
//  NeuraLinkTests
//
//  The local SLM tool-call format (docs/OPT.md item 4): well-formed calls
//  parse, and malformed, partial or non-object payloads never crash and
//  never execute.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Local tool-call parser")
struct LocalToolCallParserTests {

    @Test("A well-formed call yields its name and arguments; the first of two wins")
    func wellFormed() throws {
        let text = "Sure. <tool name=\"create_reminder\">{\"title\": \"Dentist\", \"notes\": null}</tool> Done. "
            + "<tool name=\"get_weather\">{}</tool>"
        let call = try #require(LocalToolCallParser.firstToolCall(in: text))
        #expect(call.name == "create_reminder")
        #expect(call.arguments["title"] as? String == "Dentist")
        #expect(call.arguments.keys.contains("notes"))
        #expect(LocalToolCallParser.strippedText(text) == "Sure.  Done.")
    }

    @Test("Whitespace around the name and body is tolerated")
    func whitespace() throws {
        let call = try #require(LocalToolCallParser.firstToolCall(in: "<tool   name = \"play_music\" >\n {\"query\": \"lofi\"} \n</tool>"))
        #expect(call.name == "play_music")
        #expect(call.arguments["query"] as? String == "lofi")
    }

    @Test("Malformed, partial, empty-name and non-object calls are rejected, not crashed on")
    func malformed() {
        #expect(LocalToolCallParser.firstToolCall(in: "<tool name=\"x\">{\"a\": </tool>") == nil)      // broken JSON
        #expect(LocalToolCallParser.firstToolCall(in: "<tool name=\"x\">{\"a\": 1}") == nil)            // no closing tag
        #expect(LocalToolCallParser.firstToolCall(in: "<tool name=\"\">{}</tool>") == nil)               // empty name
        #expect(LocalToolCallParser.firstToolCall(in: "<tool name=\"x\">[1, 2]</tool>") == nil)          // array, not object
        #expect(LocalToolCallParser.firstToolCall(in: "<tool name=\"x\">plain words</tool>") == nil)
        #expect(LocalToolCallParser.firstToolCall(in: "just a sentence") == nil)
        #expect(LocalToolCallParser.firstToolCall(in: "") == nil)
    }

    @Test("Stripping leaves ordinary text alone and removes every call")
    func stripping() {
        #expect(LocalToolCallParser.strippedText("  Hello there.  ") == "Hello there.")
        #expect(LocalToolCallParser.strippedText("<tool name=\"a\">{}</tool><tool name=\"b\">{}</tool>").isEmpty)
        #expect(LocalToolCallParser.strippedText("A <tool name=\"a\">{\"k\": \"<v>\"}</tool> B") == "A  B")
    }
}
