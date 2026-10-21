//
//  LocalLLMLatencyTests.swift
//  NeuraLinkTests
//
//  The local model's time-to-first-token levers: the anchored history window
//  (a turn only prefills its own tail), the SynapLink-aligned device tuning
//  (Metal everywhere unless a GPU load once died), and the KV snapshot that
//  keeps background generations from wiping the conversation's prefix. The
//  bridge test needs a real GGUF: NL_LLM_TEST_MODEL=/path/to/model.gguf.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("Local LLM latency", .serialized)
struct LocalLLMLatencyTests {

    private func msgs(_ count: Int, firstID: Int64 = 1) -> [(id: Int64, role: String)] {
        (0..<count).map { (id: firstID + Int64($0), role: $0.isMultiple(of: 2) ? "user" : "assistant") }
    }

    @Test("The history window keeps its start until it outgrows the high water mark, then jumps")
    func windowIsAnchored() {
        // Growing under the limit: always from the first message.
        var anchor: Int64?
        for count in 1...16 {
            let w = LocalLLMMemoryHierarchy.stableWindow(msgs(count), anchor: anchor, high: 16, low: 8)
            #expect(w.start == 0, "count \(count)")
            anchor = w.anchor
        }
        // One past the limit: jump to keep the last 8, opening on a user turn.
        let jumped = LocalLLMMemoryHierarchy.stableWindow(msgs(17), anchor: anchor, high: 16, low: 8)
        #expect(17 - jumped.start <= 8)
        #expect(msgs(17)[jumped.start].role == "user")
        // The following turns keep that start (same prefix) until the next jump.
        let next = LocalLLMMemoryHierarchy.stableWindow(msgs(19), anchor: jumped.anchor, high: 16, low: 8)
        #expect(next.start == jumped.start)
        #expect(next.anchor == jumped.anchor)
    }

    @Test("A forced jump halves a short window and an anchor past the list keeps it empty")
    func forcedJump() {
        let w = LocalLLMMemoryHierarchy.stableWindow(msgs(6), anchor: nil, high: 16, low: 8, forceJump: true)
        #expect(6 - w.start <= 3)
        let empty = LocalLLMMemoryHierarchy.stableWindow(msgs(4), anchor: 99, high: 16, low: 8)
        #expect(empty.start == 4)
    }

    @Test("Over a long conversation most turns only prefill their own tail")
    @MainActor
    func promptPrefixIsReused() async {
        let rows = await LocalPromptReuseTests.simulate(turns: 24)
        // Steady state: a turn's fresh tokens are the facts, the user's words
        // and the template — well under 150 — except on the few turns where
        // the window jumps.
        let heavy = rows.dropFirst().filter { $0.freshTokens > 150 }
        #expect(heavy.count <= rows.count / 4, "heavy turns: \(heavy.map { "\($0.turn):\($0.freshTokens)" })")
        let median = rows.map(\.freshTokens).sorted()[rows.count / 2]
        #expect(median < 120, "median fresh tokens \(median)")
    }

    @Test("Device tuning matches SynapLink: Metal on every device unless the GPU once failed")
    func deviceTuning() {
        let base = LLMRuntimeProfile(
            contextLength: 2048, threads: 2, gpuLayers: 999, kType: .q4_0, vType: .q4_0,
            flashAttn: .enabled, pldN: 0, pldNDraft: 0)
        let phone4GB = LLMRuntimeProfile.tuned(base, ramGB: 3.8, isSimulator: false, gpuAllowed: true)
        #expect(phone4GB.gpuLayers == 999)
        #expect(phone4GB.threads == 2 && phone4GB.kType == .q4_0)
        let unsafe = LLMRuntimeProfile.tuned(base, ramGB: 3.8, isSimulator: false, gpuAllowed: false)
        #expect(unsafe.gpuLayers == 0)
        let phone6GB = LLMRuntimeProfile.tuned(base, ramGB: 5.6, isSimulator: false, gpuAllowed: true)
        #expect(phone6GB.threads == 4 && phone6GB.kType == .q8_0 && phone6GB.vType == .q8_0)
        let sim = LLMRuntimeProfile.tuned(base, ramGB: 16, isSimulator: true, gpuAllowed: true)
        #expect(sim.gpuLayers == 0)
        #expect(LLMRuntimeProfile.resolvedContextLength(for: .llama1b) >= 2048)
    }

    @Test("Two unconfirmed GPU loads in a row keep this build on the CPU; a reset clears it")
    func gpuSentinel() throws {
        let defaults = try #require(UserDefaults(suiteName: "nl.test.gpuSentinel.\(UUID().uuidString)"))
        LLMGPUSentinel.resetForTesting()
        #expect(LLMGPUSentinel.gpuAllowed(defaults: defaults))
        LLMGPUSentinel.beginGPULoad(defaults: defaults)
        LLMGPUSentinel.confirmGPUWorks(defaults: defaults)
        LLMGPUSentinel.resetForTesting()           // next launch
        #expect(LLMGPUSentinel.gpuAllowed(defaults: defaults), "a confirmed load stays allowed")
        LLMGPUSentinel.beginGPULoad(defaults: defaults)
        LLMGPUSentinel.resetForTesting()           // died (or Xcode stopped it) before confirming
        #expect(LLMGPUSentinel.gpuAllowed(defaults: defaults), "one unconfirmed load is a strike, not a verdict")
        LLMGPUSentinel.beginGPULoad(defaults: defaults)
        LLMGPUSentinel.resetForTesting()           // died again
        #expect(!LLMGPUSentinel.gpuAllowed(defaults: defaults), "two in a row disable the GPU")
        #expect(!LLMGPUSentinel.gpuAllowed(defaults: defaults), "for the rest of this build")
        LLMGPUSentinel.reset(defaults: defaults)   // a fresh model download
        LLMGPUSentinel.resetForTesting()
        #expect(LLMGPUSentinel.gpuAllowed(defaults: defaults), "a reset tries the GPU again")
        LLMGPUSentinel.resetForTesting()
    }

    @Test("A silent generation leaves the conversation's KV prefix intact (needs NL_LLM_TEST_MODEL)")
    func snapshotKeepsPrefix() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_LLM_TEST_MODEL"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let bridge = LlamaBridge(modelPath: path, contextLength: 2048, threads: 2, gpuLayers: 0, promptLookup: false)
        else { return }
        let lock = NSLock()
        let conversation = bridge.applyChatTemplate(messages: [
            .init(role: "system", content: "You are a friendly companion who answers in one short sentence."),
            .init(role: "user", content: "I fixed my bike today and cooked pasta for my sister.")
        ]) ?? ""
        #expect(!conversation.isEmpty)
        bridge.prefill(prompt: conversation)
        let held = bridge.kvTokenCount
        #expect(held > 10)

        let gate = SilentGenerationGate()
        let silent = await gate.run(
            bridge: bridge, bridgeLock: lock,
            prompt: "Extract one fact about the user from: I like tea.\nFACT:", maxTokens: 8)
        #expect(silent != nil)
        #expect(bridge.kvTokenCount == held, "the KV tokens are back")

        // The next turn extends the conversation: it must reuse the whole held prefix.
        bridge.generate(
            prompt: conversation + "Nice!", maxNewTokens: 1,
            onToken: { _ in true }, onFinish: {})
        let stats = bridge.lastPrefillStats
        #expect(stats.reused >= held - 2, "reused \(stats.reused) of \(held)")
    }
}
