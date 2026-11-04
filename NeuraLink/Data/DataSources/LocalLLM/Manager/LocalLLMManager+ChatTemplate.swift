//
//  LocalLLMManager+ChatTemplate.swift
//  NeuraLink
//
//  Hand-rolled chat-template fallback used when a model's GGUF carries no
//  embedded template. Split out of LocalLLMManager to keep that file under
//  the file_length limit.
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

extension LocalLLMManager {

    /// Hand-rolled chat template used when the model's GGUF has no embedded
    /// template (rare, but possible with community quants). Emits Llama-3
    /// (`<|start_header_id|>`) formatting — the only family that falls through
    /// here now (the Llama-1B path; the JP slot's LLM-jp-3 carries its own GGUF
    /// template). BOS is added by the tokenizer, so it isn't included here.
    func fallbackChatPrompt(messages: [LLMChatMessage]) -> String {
        var s = ""
        for m in messages {
            s += "<|start_header_id|>\(m.role)<|end_header_id|>\n\n\(m.content)<|eot_id|>"
        }
        s += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return s
    }
}
