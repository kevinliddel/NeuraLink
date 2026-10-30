//
//  ARDYPromptTokenizer.swift
//  NeuraLink
//
//  WordPiece ids for the distilled MiniLM text encoder, from the tokenizer
//  files shipped beside the graphs, through swift-transformers. Prompts
//  longer than the encoder's context are cut keeping the final [SEP], as
//  the browser runtime does. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import Hub
import Tokenizers

struct ARDYTokenizedPrompt: Sendable {
    let ids: [Int64]
    let attentionMask: [Int64]
    let tokenTypeIds: [Int64]
}

final class ARDYPromptTokenizer: @unchecked Sendable {
    let maxLength: Int
    private let tokenizer: Tokenizer

    /// `directory` holds tokenizer.json and tokenizer_config.json.
    convenience init(directory: URL, maxLength: Int = Int(MOTION_BRIDGE_MAX_PROMPT_TOKENS)) throws {
        try self.init(
            tokenizerJSON: directory.appendingPathComponent("tokenizer.json"),
            configJSON: directory.appendingPathComponent("tokenizer_config.json"), maxLength: maxLength)
    }

    init(tokenizerJSON: URL, configJSON: URL, maxLength: Int = Int(MOTION_BRIDGE_MAX_PROMPT_TOKENS)) throws {
        self.maxLength = maxLength
        let data = try Self.config(at: tokenizerJSON)
        let config = try Self.config(at: configJSON)
        tokenizer = try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: data)
    }

    func encode(_ prompt: String) -> ARDYTokenizedPrompt {
        var ids = tokenizer.encode(text: prompt, addSpecialTokens: true)
        if ids.count > maxLength, let last = ids.last {
            ids = Array(ids.prefix(maxLength - 1)) + [last]
        }
        let wide = ids.map(Int64.init)
        return ARDYTokenizedPrompt(ids: wide, attentionMask: [Int64](repeating: 1, count: wide.count), tokenTypeIds: [Int64](repeating: 0, count: wide.count))
    }

    private static func config(at url: URL) throws -> Config {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [NSString: Any] else {
            throw ARDYMotionRuntimeError.manifestUnreadable(url.path)
        }
        return Config(dictionary)
    }
}
