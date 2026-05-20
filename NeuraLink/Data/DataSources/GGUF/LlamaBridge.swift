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
    private let label: String

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
    ///   - label:         Short tag prepended to benchmark logs. Defaults to
    ///                    the model filename stem.
    init?(
        modelPath: String,
        contextLength: Int32 = 2048,
        threads: Int32 = 4,
        gpuLayers: Int32 = 999,
        kType: LlamaKVType = .q4_0,
        vType: LlamaKVType = .q4_0,
        promptLookup: Bool = true,
        label: String = ""
    ) {
        self.label = label.isEmpty
            ? URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
            : label
        var layers = gpuLayers
        #if targetEnvironment(simulator)
        layers = 0 // CPU-only in Simulator to avoid MTLCompilerService crashes
        #else
        // On real older devices with < 5.0 GB of RAM (like iPhone 11/12/13), Metal shader compilation
        // spikes memory usage and triggers jetsam/compiler daemon crashes. Force CPU-only to guarantee stability.
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb < 5.0 {
            nlLog("[LlamaBridge] Device RAM (\(String(format: "%.1f", gb)) GB) is under 5.0 GB. Forcing CPU-only execution for rock-solid stability.", level: .info)
            layers = 0
        }
        #endif
        handle = llama_bridge_create(modelPath, contextLength, threads, layers, kType.rawValue, vType.rawValue)
        
        // If Metal/GPU initialization fails on real hardware (e.g. pre-A14 devices or MTLCompilerService XPC error),
        // gracefully fall back to CPU-only execution.
        if handle == nil && layers > 0 {
            nlLog("[LlamaBridge] Metal/GPU initialization failed. Retrying with CPU-only (gpuLayers = 0)...", level: .error)
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
        let stats = GenerationStats()
        let benchLabel = label
        let weakHandle = handle
        let timedOnToken: (String) -> Bool = { token in
            if stats.firstTokenTime == nil {
                stats.firstTokenTime = CFAbsoluteTimeGetCurrent()
            }
            stats.tokenCount += 1
            return onToken(token)
        }
        let timedOnFinish: () -> Void = {
            var reused: Int32 = 0
            var newTokens: Int32 = 0
            var prefillMs: Double = 0
            llama_bridge_get_prefill_stats(weakHandle, &reused, &newTokens, &prefillMs)
            LlamaBridge.logBenchmark(
                label: benchLabel, stats: stats,
                prefillReused: reused, prefillNew: newTokens, prefillMs: prefillMs)
            onFinish()
        }

        let box = CallbackBox(onToken: timedOnToken, onFinish: timedOnFinish)
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

    // MARK: - Benchmark logging

    private static func logBenchmark(
        label: String,
        stats: GenerationStats,
        prefillReused: Int32,
        prefillNew: Int32,
        prefillMs: Double
    ) {
        let end = CFAbsoluteTimeGetCurrent()
        let ttftSec = (stats.firstTokenTime ?? end) - stats.start
        let decodeWindow = end - (stats.firstTokenTime ?? end)
        let decodeTokens = max(0, stats.tokenCount - 1)
        let decodeTps = decodeWindow > 0.001
            ? Double(decodeTokens) / decodeWindow
            : 0
        let prefillTps = prefillMs > 1.0
            ? Double(prefillNew) / (prefillMs / 1000)
            : 0
        let totalElapsed = end - stats.start
        let line = String(
            format: "[Bench] %@ tokens=%d ttft=%.0fms decode=%.2ftok/s prefill=%d+%d@%.0fms(%.1ftok/s) elapsed=%.2fs",
            label, stats.tokenCount, ttftSec * 1000, decodeTps,
            prefillReused, prefillNew, prefillMs, prefillTps, totalElapsed)
        nlLog(line, level: .info)
    }

    /// Signals the in-progress generation to stop after the current token.
    func cancel() {
        llama_bridge_cancel(handle)
    }

    /// Synchronously prefills the KV cache for `prompt` without generating
    /// tokens. Blocks the calling thread — dispatch to a background queue.
    /// Caller MUST serialise with `generate(...)` (llama.cpp is not
    /// thread-safe on a single context).
    func prefill(prompt: String) {
        llama_bridge_prefill(handle, prompt)
    }

    // MARK: - KV cache persistence

    /// Save the current KV cache state to `path`. Returns the number of
    /// bytes written, or 0 on failure / empty cache. Blocking — dispatch
    /// to a background queue, and serialise with prefill/generate calls.
    @discardableResult
    func saveKVState(path: String) -> Int {
        return Int(llama_bridge_save_kv_state(handle, path))
    }

    /// Restore a previously-saved KV cache state from `path`. Returns the
    /// number of tokens restored, or 0 on failure. On failure the bridge is
    /// left with an empty KV cache — safe to fall through to a normal
    /// prefill/generate afterwards. Blocking — dispatch and serialise as
    /// with `saveKVState`.
    @discardableResult
    func loadKVState(path: String) -> Int {
        return Int(llama_bridge_load_kv_state(handle, path))
    }

    /// Number of tokens currently materialised in the KV cache. Useful for
    /// benchmark logging ("loaded N tokens from disk cache").
    var kvTokenCount: Int {
        return Int(llama_bridge_kv_token_count(handle))
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

// MARK: - GenerationStats

/// Per-call timing scratch space. Mutated by the onToken/onFinish closures
/// captured in `generate`; both fire on the same C thread so no locking.
private final class GenerationStats {
    let start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    var firstTokenTime: CFAbsoluteTime?
    var tokenCount: Int = 0
}
