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
        vType: LlamaKVType = .q4_0,
        promptLookup: Bool = true
    ) {
        var layers = gpuLayers
        #if targetEnvironment(simulator)
        layers = 0 // CPU-only in Simulator to avoid MTLCompilerService crashes
        #else
        // On real older devices with < 5.0 GB of RAM (like iPhone 11/12/13), Metal shader compilation
        // spikes memory usage and triggers jetsam/compiler daemon crashes. Force CPU-only to guarantee stability.
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb < 5.0 {
            print("[LlamaBridge] Device RAM (\(String(format: "%.1f", gb)) GB) is under 5.0 GB. Forcing CPU-only execution for rock-solid stability.")
            layers = 0
        }
        #endif
        handle = llama_bridge_create(modelPath, contextLength, threads, layers, kType.rawValue, vType.rawValue)
        
        // If Metal/GPU initialization fails on real hardware (e.g. pre-A14 devices or MTLCompilerService XPC error),
        // gracefully fall back to CPU-only execution.
        if handle == nil && layers > 0 {
            print("[LlamaBridge] Metal/GPU initialization failed. Retrying with CPU-only (gpuLayers = 0)...")
            handle = llama_bridge_create(modelPath, contextLength, threads, 0, kType.rawValue, vType.rawValue)
        }
        
        guard handle != nil else { return nil }
        // Prompt-Lookup Decoding is on by default for every engine: it's a
        // free 1.5–2× tok/s win on conversational repetition and gracefully
        // no-ops when no n-gram match is found.
        if promptLookup {
            llama_bridge_set_prompt_lookup(handle, true, 0, 0)
        }
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

    // MARK: - Prompt-lookup decoding

    /// Toggle prompt-lookup speculative decoding. Passing `n` or `nDraft`
    /// non-positive keeps the C-side defaults (n=3, nDraft=5).
    func enablePromptLookup(_ enabled: Bool, n: Int32 = 0, nDraft: Int32 = 0) {
        llama_bridge_set_prompt_lookup(handle, enabled, n, nDraft)
    }

    // MARK: - Chat template

    /// Formats `messages` into a single prompt string using the model's own
    /// chat template (read from GGUF metadata). Returns `nil` if the model
    /// has no template or the formatting failed — callers should then fall
    /// back to a hand-rolled template.
    func applyChatTemplate(
        messages: [LLMChatMessage],
        addGenerationPrompt: Bool = true
    ) -> String? {
        guard let handle, !messages.isEmpty else { return nil }

        // Pin the UTF-8 storage for the duration of the call so the C-side
        // pointers stay valid across nested closures.
        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        cStrings.reserveCapacity(messages.count * 2)
        for msg in messages {
            cStrings.append(strdup(msg.role))
            cStrings.append(strdup(msg.content))
        }
        defer { cStrings.forEach { if let p = $0 { free(p) } } }

        var roles: [UnsafePointer<CChar>?]    = []
        var contents: [UnsafePointer<CChar>?] = []
        roles.reserveCapacity(messages.count)
        contents.reserveCapacity(messages.count)
        for i in 0..<messages.count {
            roles.append(cStrings[i * 2].map { UnsafePointer($0) })
            contents.append(cStrings[i * 2 + 1].map { UnsafePointer($0) })
        }

        let totalChars = messages.reduce(0) { $0 + $1.role.count + $1.content.count }
        var bufSize = max(512, totalChars * 2 + 256)

        for _ in 0..<3 {
            var buffer = [CChar](repeating: 0, count: bufSize)
            let written = buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
                roles.withUnsafeMutableBufferPointer { rolesPtr in
                    contents.withUnsafeMutableBufferPointer { contentsPtr in
                        llama_bridge_apply_chat_template(
                            handle,
                            rolesPtr.baseAddress,
                            contentsPtr.baseAddress,
                            Int32(messages.count),
                            addGenerationPrompt,
                            bufPtr.baseAddress,
                            Int32(bufSize)
                        )
                    }
                }
            }
            if written < 0 { return nil }
            if Int(written) < bufSize { return String(cString: buffer) }
            bufSize = Int(written) + 1
        }
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
