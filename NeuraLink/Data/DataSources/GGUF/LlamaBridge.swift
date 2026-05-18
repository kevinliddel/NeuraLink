//
//  LlamaBridge.swift
//  NeuraLink
//
//  Swift wrapper around the opaque C handle exposed by llama_bridge.h.
//  Owns the handle's lifetime and converts Swift closures to C callbacks
//  via `Unmanaged` without leaking memory.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

// MARK: - LlamaBridge

/// Manages a single llama.cpp inference context.
/// One instance per active `GGUFLlamaEngine` — destroyed when the engine unloads.
final class LlamaBridge {

    // MARK: - Properties

    private var handle: OpaquePointer?

    var version: String {
        String(cString: llama_bridge_version())
    }

    // MARK: - Init / deinit

    /// Returns `nil` if the model file is missing or memory allocation fails.
    ///
    /// - Parameters:
    ///   - modelPath:     Absolute path to the `.gguf` file.
    ///   - contextLength: KV-cache token capacity (2048 for 4 GB devices).
    ///   - threads:       CPU threads for non-Metal ops (4 on A13 Bionic).
    ///   - gpuLayers:     Transformer layers to offload to Metal (999 = all).
    ///   - kType:         KV cache K quantization (default: .q4_0).
    ///   - vType:         KV cache V quantization (default: .q4_0).
    init?(
        modelPath: String,
        contextLength: Int32 = 2048,
        threads: Int32 = 4,
        gpuLayers: Int32 = 999,
        kType: LlamaKVType = .q4_0,
        vType: LlamaKVType = .q4_0
    ) {
        handle = llama_bridge_create(modelPath, contextLength, threads, gpuLayers, kType.rawValue, vType.rawValue)
        guard handle != nil else { return nil }
    }

    deinit {
        llama_bridge_free(handle)
    }

    // MARK: - Inference

    /// Generates tokens for `prompt`. Blocks the calling thread — run inside a detached Task.
    ///
    /// - Parameters:
    ///   - prompt:        Full prompt string in model-specific chat format.
    ///   - maxNewTokens:  Maximum new tokens to generate.
    ///   - onToken:       Called per token. Return `false` to stop early.
    ///   - onFinish:      Called once when generation ends or is cancelled.
    func generate(
        prompt: String,
        maxNewTokens: Int32,
        onToken: @escaping (String) -> Bool,
        onFinish: @escaping () -> Void
    ) {
        let box = CallbackBox(onToken: onToken, onFinish: onFinish)
        // passRetained: the C callbacks keep the box alive until on_finish fires.
        let ptr = Unmanaged.passRetained(box).toOpaque()

        llama_bridge_generate(
            handle,
            prompt,
            maxNewTokens,
            // on_token — must NOT retain `continuation`; return value stops generation.
            { rawToken, ctx -> Bool in
                guard let rawToken, let ctx else { return false }
                let callbackBox = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                return callbackBox.onToken(String(cString: rawToken))
            },
            // on_finish — takes ownership of the retained box and releases it.
            { ctx in
                guard let ctx else { return }
                let callbackBox = Unmanaged<CallbackBox>.fromOpaque(ctx).takeRetainedValue()
                callbackBox.onFinish()
            },
            ptr
        )
    }

    /// Signals the in-progress generation to stop after the current token.
    func cancel() {
        llama_bridge_cancel(handle)
    }

    // MARK: - Chat template

    /// Currently returns `nil` so callers fall back to the hand-rolled chat
    /// template in `LocalLLMManager.fallbackChatPrompt`. The bridge-side
    /// `llama_bridge_apply_chat_template` path is temporarily removed while
    /// we investigate a Metal-compile regression on iPhone 11.
    func applyChatTemplate(
        messages: [LLMChatMessage],
        addGenerationPrompt: Bool = true
    ) -> String? {
        return nil
    }
}

// MARK: - CallbackBox

/// Heap-allocated closure pair passed through the void* C callback context.
private final class CallbackBox {
    let onToken: (String) -> Bool
    let onFinish: () -> Void

    init(onToken: @escaping (String) -> Bool, onFinish: @escaping () -> Void) {
        self.onToken  = onToken
        self.onFinish = onFinish
    }
}
