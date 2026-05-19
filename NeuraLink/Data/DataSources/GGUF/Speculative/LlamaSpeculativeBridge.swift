//
//  LlamaSpeculativeBridge.swift
//  NeuraLink
//
//  Swift wrapper around the opaque speculative-decoding handle exposed by
//  llama_bridge.h. Owns the handle's lifetime and converts Swift closures
//  to C callbacks via `Unmanaged` without leaking memory.
//
//  Pairs a 1.5B draft model with a 7B target model and is activated by
//  `GGUFSpeculativeEngine` only when both Qwen-2.5-7B and Qwen-2.5-1.5B
//  are on disk. Falls back to `GGUFQwen7BEngine` otherwise.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

final class LlamaSpeculativeBridge {

    // MARK: - Properties

    private var handle: OpaquePointer?

    // MARK: - Init / deinit

    /// Returns `nil` if either model fails to load, their vocabularies
    /// differ, or context allocation fails. The bridge does not own a
    /// `version` accessor — diagnostics are read via the regular
    /// `LlamaBridge.version` getter on the target's standalone engine.
    init?(
        targetPath: String,
        draftPath: String,
        contextLength: Int32 = 2048,
        threads: Int32 = 6,
        gpuLayers: Int32 = 999,
        nDraft: Int32 = 4,
        kType: LlamaKVType = .q4_0,
        vType: LlamaKVType = .q4_0
    ) {
        var layers = gpuLayers
        #if targetEnvironment(simulator)
        layers = 0  // CPU-only in Simulator to mirror LlamaBridge's posture.
        #else
        // < 5 GB devices never reach the speculative engine (they default
        // to .llama1b which doesn't use this bridge), but keep the same
        // defensive posture for safety in case selectedConfig is forced.
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb < 5.0 { layers = 0 }
        #endif

        handle = llama_bridge_spec_create(
            targetPath, draftPath,
            contextLength, threads, layers,
            kType.rawValue, vType.rawValue,
            nDraft
        )
        // Retry CPU-only if Metal init failed on real hardware.
        if handle == nil && layers > 0 {
            nlLog("[SpecBridge] Metal init failed for target+draft. Retrying with CPU-only…", level: .error)
            handle = llama_bridge_spec_create(
                targetPath, draftPath,
                contextLength, threads, 0,
                kType.rawValue, vType.rawValue,
                nDraft
            )
        }
        guard handle != nil else { return nil }
    }

    deinit {
        llama_bridge_spec_free(handle)
    }

    // MARK: - Inference

    /// Generate tokens via speculative decoding. Blocks the calling thread
    /// — run inside a detached Task. Each token piece is delivered via
    /// `onToken`; return `false` from it to stop early. `onFinish` fires
    /// exactly once (whether the run completes, hits EOG, or is cancelled).
    func generate(
        prompt: String,
        maxNewTokens: Int32,
        onToken: @escaping (String) -> Bool,
        onFinish: @escaping () -> Void
    ) {
        let box = SpecCallbackBox(onToken: onToken, onFinish: onFinish)
        let ptr = Unmanaged.passRetained(box).toOpaque()

        llama_bridge_spec_generate(
            handle,
            prompt,
            maxNewTokens,
            { rawToken, ctx -> Bool in
                guard let rawToken, let ctx else { return false }
                let cb = Unmanaged<SpecCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
                return cb.onToken(String(cString: rawToken))
            },
            { ctx in
                guard let ctx else { return }
                let cb = Unmanaged<SpecCallbackBox>.fromOpaque(ctx).takeRetainedValue()
                cb.onFinish()
            },
            ptr
        )
    }

    /// Signals the in-progress speculative generation to stop after the
    /// current token.
    func cancel() {
        llama_bridge_spec_cancel(handle)
    }

    // MARK: - Chat template

    /// Formats `messages` into a single prompt string using the target
    /// model's chat template (the draft's template is irrelevant since it
    /// never sees the user-facing prompt).
    func applyChatTemplate(
        messages: [LLMChatMessage],
        addGenerationPrompt: Bool = true
    ) -> String? {
        guard let handle, !messages.isEmpty else { return nil }

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
                        llama_bridge_spec_apply_chat_template(
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
/// Named distinctly from `LlamaBridge`'s private `CallbackBox` to avoid any
/// linker ambiguity if Swift ever surfaces one — they're independent types.
private final class SpecCallbackBox {
    let onToken: (String) -> Bool
    let onFinish: () -> Void

    init(onToken: @escaping (String) -> Bool, onFinish: @escaping () -> Void) {
        self.onToken  = onToken
        self.onFinish = onFinish
    }
}
