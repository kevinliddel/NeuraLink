//
//  LLMjpReplyDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: runs the real LLM-jp-3 model on the simulator through the
//  app's own prompt builders, in the old Llama-3 fallback markup and in the
//  model's native "### 指示 / ### 応答" format, plus a Japanese silence-break
//  cue, and writes every reply (raw and after the stop/label filters and the
//  cue validator) to a file. Set NL_LLMJP_MODEL (the .gguf) and
//  NL_LLM_DIAG_DIR to run.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("LLM-jp reply diagnostic", .serialized)
struct LLMjpReplyDiagnostic {

    @Test("Compare LLM-jp replies in the fallback and native formats when NL_LLMJP_MODEL is set")
    @MainActor
    func compare() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["NL_LLMJP_MODEL"], let out = env["NL_LLM_DIAG_DIR"],
              FileManager.default.fileExists(atPath: model),
              let bridge = LlamaBridge(modelPath: model, contextLength: 1024, threads: 4, gpuLayers: 0, promptLookup: false)
        else { return }
        let hierarchy = LocalLLMMemoryHierarchy.shared
        let character = "oz"
        let base = LocalLLMPromptStore.defaultPrompt(for: character, config: .llmJp3)

        func run(_ prompt: String, filtered: Bool) -> (raw: String, shown: String) {
            var raw = ""
            var shown = ""
            var stops = StopSequenceFilter()
            bridge.generate(prompt: prompt, maxNewTokens: 60, onToken: { piece in
                raw += piece
                guard filtered else { return true }
                shown += stops.feed(piece)
                return !stops.stopped
            }, onFinish: {})
            if filtered { shown += stops.flush() }
            return (raw, filtered ? LeadingLabelFilter.strip(shown, names: ["Oz", "オズ"]) : raw)
        }
        func llama3(_ messages: [LLMChatMessage]) -> String {
            messages.map { "<|start_header_id|>\($0.role)<|end_header_id|>\n\n\($0.content)<|eot_id|>" }.joined()
                + "<|start_header_id|>assistant<|end_header_id|>\n\n"
        }

        var report = "# LLM-jp-3 replies\n\n"
        for input in ["おもばれもらった", "今日はちょっと寒いですね", "おすすめの紅茶はある？"] {
            let messages = await hierarchy.buildMessages(
                userInput: input, config: .llmJp3, characterName: character, baseSystemPrompt: base)
            let old = run(llama3(messages), filtered: false)
            let new = run(LLMjpPromptFormat.render(messages, addGenerationPrompt: true), filtered: true)
            report += "## 「\(input)」\n- OLD (Llama-3 fallback) raw: \(old.raw.debugDescription)\n"
            report += "- NEW (native) raw: \(new.raw.debugDescription)\n- NEW shown: \(new.shown.debugDescription)\n\n"
        }

        let cue = ProactivePresenceManager.smallTalkEventJapanese(
            name: "Oz", timeOfDay: "午後", angle: .checkIn, previousLine: nil)
        let cueMessages = await hierarchy.buildCueMessages(
            instruction: cue, config: .llmJp3, characterName: character, baseSystemPrompt: base)
        for attempt in 1...3 {
            let reply = run(LLMjpPromptFormat.render(cueMessages, addGenerationPrompt: true), filtered: true)
            let said = CueReplyValidator.clean(reply.shown, instruction: cue, names: ["Oz", "オズ"])
            report += "## Silence cue #\(attempt)\n- raw: \(reply.raw.debugDescription)\n- spoken: \((said ?? "⟨dropped⟩").debugDescription)\n\n"
        }
        let oldCue = "（日本語で回答）" + ProactivePresenceManager.smallTalkEvent(timeOfDay: "afternoon", stage: "Friends", factSeed: nil)
        let old = run(llama3([.init(role: "system", content: base), .init(role: "user", content: oldCue)]), filtered: false)
        report += "## OLD silence path (English instruction as the user's words, fallback markup)\n- raw: \(old.raw.debugDescription)\n"

        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try report.write(to: dir.appendingPathComponent("llmjp_replies.md"), atomically: true, encoding: .utf8)
    }
}
