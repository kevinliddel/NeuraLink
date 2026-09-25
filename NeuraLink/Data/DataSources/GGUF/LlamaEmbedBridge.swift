//
//  LlamaEmbedBridge.swift
//  NeuraLink
//
//  Swift wrapper around the opaque C embedding handle in llama_embed_bridge.h
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C2). One instance per loaded
//  embedding model; thread-safe (the C side serialises calls).
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

final class LlamaEmbedBridge {

    private var handle: OpaquePointer?
    let dimension: Int

    /// Returns nil when the model file is missing or fails to initialise.
    init?(modelPath: String, contextLength: Int32 = 512, threads: Int32 = 2, gpuLayers: Int32 = 0) {
        guard let created = llama_embed_create(modelPath, contextLength, threads, gpuLayers) else { return nil }
        handle = created
        dimension = Int(llama_embed_dimension(created))
        guard dimension > 0 else {
            llama_embed_free(created)
            handle = nil
            return nil
        }
    }

    deinit {
        llama_embed_free(handle)
    }

    /// L2-normalised embedding of `text`, or nil on failure.
    func embed(_ text: String) -> [Double]? {
        guard let handle else { return nil }
        var out = [Float](repeating: 0, count: dimension)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            llama_embed_text(handle, text, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == Int32(dimension) else {
            nlLog("[LlamaEmbedBridge] embed failed (\(written))", level: .warning)
            return nil
        }
        return out.map(Double.init)
    }
}
