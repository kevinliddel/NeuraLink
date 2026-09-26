//
//  GGUFLlamaEngine+ToolGrammar.swift
//  NeuraLink
//
//  Installs the curated tool grammar once per model load
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §A1). The grammar is lazy — sampling
//  stays free until the model emits `<tool` — so the persona voice is
//  untouched and there is no per-turn sampler swap.
//

import Foundation

extension GGUFLlamaEngine {

    func installLocalToolGrammar() {
        let tools = ToolGrammarBuilder.tools(named: ToolGrammarBuilder.localToolNames, from: AppFunctionTool.all)
        guard let gbnf = ToolGrammarBuilder.gbnf(for: tools) else { return }
        let ok = setToolGrammar(
            gbnf: gbnf, root: ToolGrammarBuilder.rootRule, triggerPatterns: [ToolGrammarBuilder.triggerPattern])
        nlLog("[GGUFEngine] Tool grammar \(ok ? "installed" : "REJECTED") for \(tools.map(\.name))", level: ok ? .info : .error)
    }

    func setToolGrammar(gbnf: String, root: String, triggerPatterns: [String]) -> Bool {
        guard let bridge else { return false }
        return bridge.setToolGrammar(gbnf: gbnf, root: root, triggerPatterns: triggerPatterns)
    }
}
