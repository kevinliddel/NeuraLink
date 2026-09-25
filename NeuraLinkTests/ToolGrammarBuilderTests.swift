//
//  ToolGrammarBuilderTests.swift
//  NeuraLinkTests
//
//  GBNF + prompt generation for local tool calls (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §A1).
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Tool grammar builder")
struct ToolGrammarBuilderTests {

    @Test("Curated tools all parse from the shared schemas")
    func curatedTools() {
        let tools = ToolGrammarBuilder.tools(named: ToolGrammarBuilder.localToolNames, from: AppFunctionTool.all)
        #expect(tools.map(\.name) == ToolGrammarBuilder.localToolNames)
        let reminder = tools.first { $0.name == AppFunctionTool.createReminder }
        #expect(reminder?.properties.map(\.name) == ["title", "notes"])
        #expect(reminder?.properties.map(\.required) == [true, false])
    }

    @Test("GBNF covers every tool with required/optional keys, enums and scalars")
    func gbnf() throws {
        let schemas: [[String: Any]] = [
            ["name": "pose", "parameters": ["type": "object", "properties": [
                "pose": ["type": "string", "enum": ["cool", "relax"]],
                "count": ["type": "integer"],
                "loud": ["type": "boolean"]
            ], "required": ["pose"]]],
            ["name": "unsupported", "parameters": ["type": "object", "properties": [
                "items": ["type": "array"]], "required": ["items"]]]
        ]
        let tools = ToolGrammarBuilder.tools(named: ["pose", "unsupported"], from: schemas)
        #expect(tools.count == 1, "array-typed schema is skipped")
        let grammar = try #require(ToolGrammarBuilder.gbnf(for: tools))
        #expect(grammar.contains("root ::= \"<tool name=\\\"\" call \"</tool>\""))
        #expect(grammar.contains("call ::= call-pose"))
        #expect(grammar.contains("call-pose ::= \"pose\\\">\" obj-pose"))
        #expect(grammar.contains("enum-pose-pose ::= \"\\\"cool\\\"\" | \"\\\"relax\\\"\""))
        #expect(grammar.contains("( \",\" ws \"\\\"count\\\"\" ws \":\" ws integer ws )?"))
        #expect(grammar.contains("boolean ::= \"true\" | \"false\""))
        #expect(ToolGrammarBuilder.gbnf(for: []) == nil)
    }

    @Test("Prompt block shows one filled-in example per tool")
    func promptBlock() {
        let tools = ToolGrammarBuilder.tools(named: ToolGrammarBuilder.localToolNames, from: AppFunctionTool.all)
        let block = ToolGrammarBuilder.promptBlock(for: tools)
        #expect(block.contains("<tool name=\"get_weather\">{\"location\":\"…\"}</tool>"))
        #expect(block.contains("<tool name=\"remember_fact\">{\"subject\":\"…\",\"predicate\":\"…\",\"object\":\"…\"}</tool>"))
        #expect(!block.contains("notes"), "optional keys stay out of the example")
        #expect(block.count < 520, "≈ 60–120 tokens on a 1B; keep it tight")
    }

    @Test("Parser round-trips a grammar-shaped call")
    func parserRoundTrip() throws {
        let text = "Sure! <tool name=\"create_reminder\">{\"title\":\"Call mum\",\"notes\":\"tonight\"}</tool>"
        let call = try #require(LocalToolCallParser.firstToolCall(in: text))
        #expect(call.name == "create_reminder")
        #expect(call.arguments["title"] as? String == "Call mum")
        #expect(LocalToolCallParser.strippedText(text).trimmingCharacters(in: .whitespaces) == "Sure!")
    }
}
