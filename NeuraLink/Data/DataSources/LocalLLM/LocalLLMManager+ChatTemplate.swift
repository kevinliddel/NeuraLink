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
    /// template (rare but possible with community quants). Covers the three
    /// families we ship: Gemma (`<start_of_turn>`), Qwen/ChatML
    /// (`<|im_start|>`), and Llama-3 (`<|start_header_id|>`). BOS is added by
    /// the tokenizer, so no family includes it literally here.
    func fallbackChatPrompt(
        messages: [LLMChatMessage],
        useQwen: Bool,
        isGemma: Bool
    ) -> String {
        if isGemma {
            // Gemma 2/3 has only `user`/`model` roles and NO system turn —
            // fold any system message(s) into the following user turn.
            var s = ""
            var pendingSystem = ""
            for m in messages {
                switch m.role {
                case "system":
                    pendingSystem += (pendingSystem.isEmpty ? "" : "\n\n") + m.content
                case "assistant", "model":
                    s += "<start_of_turn>model\n\(m.content)<end_of_turn>\n"
                default: // user
                    let content = pendingSystem.isEmpty
                        ? m.content
                        : "\(pendingSystem)\n\n\(m.content)"
                    pendingSystem = ""
                    s += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                }
            }
            if !pendingSystem.isEmpty {
                s += "<start_of_turn>user\n\(pendingSystem)<end_of_turn>\n"
            }
            s += "<start_of_turn>model\n"
            return s
        }
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
