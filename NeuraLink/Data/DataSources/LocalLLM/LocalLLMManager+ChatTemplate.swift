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
    /// template (rare, but possible with community quants). Covers the two
    /// prompt families our local models fall back to: Qwen/ChatML
    /// (`<|im_start|>`) and Llama-3 (`<|start_header_id|>`). The JP slot
    /// (LLM-jp-3) and every other shipped model carry their own GGUF chat
    /// template, so this is only a safety net. BOS is added by the tokenizer,
    /// so no family includes it literally here.
    func fallbackChatPrompt(
        messages: [LLMChatMessage],
        useQwen: Bool
    ) -> String {
        if useQwen {
            var s = ""
            for m in messages {
                s += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n"
            }
            s += "<|im_start|>assistant\n"
            return s
        }
        var s = ""
        for m in messages {
            s += "<|start_header_id|>\(m.role)<|end_header_id|>\n\n\(m.content)<|eot_id|>"
        }
        s += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return s
    }
}
