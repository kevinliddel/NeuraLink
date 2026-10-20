//
//  SilentGenerationGate.swift
//  NeuraLink
//
//  Background generations (memory extraction, consolidation, reflections,
//  chat titles) share the chat model with the user's turns. Run naively they
//  did two things SynapLink's chat never suffers: they replaced the
//  conversation's KV cache with their own prompt, so the next user turn had
//  to prefill the whole system prompt and history again, and they held the
//  engine, so a user turn arriving meanwhile was dropped. The gate fixes
//  both: a silent run snapshots the KV state first and restores it after, and
//  a user turn preempts it at the next token. Shared by both GGUF engines.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

final class SilentGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var preempted = false

    /// A user-facing turn wants the engine: stop the silent run at its next token.
    func preemptIfActive() {
        lock.withLock { if active { preempted = true } }
    }

    private var isPreempted: Bool { lock.withLock { preempted } }

    /// Runs one silent generation on `bridge` under `bridgeLock`, leaving the
    /// KV cache exactly as it found it. Returns the text, or nil when there is
    /// no model or a user turn preempted it (callers retry later).
    func run(bridge: LlamaBridge, bridgeLock: NSLock, prompt: String, maxTokens: Int) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async { [self] in
                bridgeLock.lock()
                defer { bridgeLock.unlock() }
                lock.withLock {
                    active = true
                    preempted = false
                }
                let snapshot = bridge.snapshotKV()
                var text = ""
                bridge.generate(
                    prompt: prompt, maxNewTokens: Int32(maxTokens),
                    onToken: { [self] token in
                        text += token
                        return !isPreempted
                    },
                    onFinish: {})
                if let snapshot {
                    let restored = bridge.restoreKV(snapshot)
                    nlLog("[SilentGen] KV \(restored ? "restored" : "restore FAILED") (\(snapshot.tokenCount) tokens)",
                          level: restored ? .debug : .warning)
                }
                let wasPreempted = lock.withLock { () -> Bool in
                    active = false
                    return preempted
                }
                if wasPreempted { nlLog("[SilentGen] Preempted by a user turn", level: .info) }
                continuation.resume(returning: wasPreempted ? nil : text)
            }
        }
    }
}
