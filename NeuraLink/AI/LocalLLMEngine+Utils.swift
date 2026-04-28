//
//  LocalLLMEngine+Utils.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import CoreML
import Foundation

extension LocalLLMEngine {
    // MARK: - Tensor name discovery

    /// Inspects each model's interface once at load time and stores the tensor
    /// names used during inference. Logs the full interface for debugging.
    internal func discoverTensorNames() {
        for (i, chunk) in bodyChunks.enumerated() {
            let inputs = chunk.modelDescription.inputDescriptionsByName
            let outputs = chunk.modelDescription.outputDescriptionsByName
            print("[LlamaEngine] chunk\(i+1) inputs: \(inputs.keys.sorted())")
            print("[LlamaEngine] chunk\(i+1) outputs: \(outputs.keys.sorted())")
            if #available(iOS 17.0, *) {
                let states = chunk.modelDescription.stateDescriptionsByName
                print("[LlamaEngine] chunk\(i+1) states: \(states.keys.sorted())")
            }

            if i == 0 {
                chunk1TokenInputKey =
                    inputs.keys.first { $0.lowercased().contains("id") }
                    ?? inputs.keys.first { !$0.lowercased().contains("hidden") }
                    ?? "input_ids"
                hiddenInputKey =
                    inputs.keys.first { $0.lowercased().contains("hidden") }
                    ?? "hidden_states"
                hiddenOutputKey =
                    outputs.keys.first { $0.lowercased().contains("hidden") }
                    ?? "hidden_states"
            }
        }

        if let proc = cacheProcessor {
            print(
                "[LlamaEngine] cache-processor inputs: \(proc.modelDescription.inputDescriptionsByName.keys.sorted())"
            )
            print(
                "[LlamaEngine] cache-processor outputs: \(proc.modelDescription.outputDescriptionsByName.keys.sorted())"
            )
        }

        if let logit = logitProcessor {
            let inputs = logit.modelDescription.inputDescriptionsByName
            let outputs = logit.modelDescription.outputDescriptionsByName
            print("[LlamaEngine] logit-processor inputs: \(inputs.keys.sorted())")
            print("[LlamaEngine] logit-processor outputs: \(outputs.keys.sorted())")

            nextTokenOutputKey =
                outputs.keys.first { $0.lowercased().contains("token") }
                ?? outputs.keys.first { !$0.lowercased().contains("logit") }
                ?? "next_token"
        }
    }

    // MARK: - Helpers

    internal func tokenize(text: String) -> [Int32] {
        guard let tok = tokenizer else { return [1] }
        return tok.encode(text: text).map { Int32($0) }
    }

    internal func decode(tokenID: Int32) -> String {
        tokenizer?.decode(tokens: [Int(tokenID)], skipSpecialTokens: true) ?? ""
    }

    internal func argmax(logits: MLMultiArray) -> Int32 {
        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        var maxVal: Float = -.greatestFiniteMagnitude
        var maxIdx: Int32 = 0
        for i in 0..<logits.count {
            if ptr[i] > maxVal {
                maxVal = ptr[i]
                maxIdx = Int32(i)
            }
        }
        return maxIdx
    }
}
