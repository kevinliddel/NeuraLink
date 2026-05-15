//
//  LlamaKVType.swift
//  NeuraLink
//
//  Maps GGML types to integer constants for use with llama_bridge.
//

import Foundation

enum LlamaKVType: Int32 {
    case f32 = 0
    case f16 = 1
    case q4_0 = 2
    case q4_1 = 3
    case q5_0 = 6
    case q5_1 = 7
    case q8_0 = 8
}
