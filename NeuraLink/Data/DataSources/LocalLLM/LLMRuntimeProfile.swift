//
//  LLMRuntimeProfile.swift
//  NeuraLink
//
//  Single source of truth for per-device-tier llama.cpp runtime parameters
//  (context length, threads, GPU layers, KV-cache quantization, flash-attn
//  mode, prompt-lookup window). Replaces the values that were previously
//  hardcoded and duplicated across the six GGUF engines.
//
//  `resolve(for:)` maps the selected model slot plus the live device (RAM,
//  Simulator) to concrete params. Per-tier tuning lives here: the device
//  measurement sweep locks its winning KV-quant / flash-attn / thread values
//  into this one function so the engines never carry magic numbers again.
//

import Foundation

/// Flash-attention mode forwarded to the bridge. Raw values match llama.cpp's
/// `enum llama_flash_attn_type` exactly (AUTO = -1, DISABLED = 0, ENABLED = 1)
/// so the C bridge can `static_cast` straight to the enum with no translation.
enum FlashAttnMode: Int32 {
    case auto     = -1
    case disabled = 0
    case enabled  = 1
}

struct LLMRuntimeProfile {
    var contextLength: Int32
    var threads: Int32
    var gpuLayers: Int32
    var kType: LlamaKVType
    var vType: LlamaKVType
    var flashAttn: FlashAttnMode
    /// 0 keeps the C-side prompt-lookup defaults (n = 3, n_draft = 5).
    var pldN: Int32
    var pldNDraft: Int32

    /// Per-model baseline parameters, exactly as locked in by the device
    /// measurement sweep. `resolve(for:)` layers the device-dependent
    /// adjustments (CPU fallback, thread cap, RAM-scaled n_ctx) on top.
    ///
    /// Base values below reproduce the pre-refactor hardcoded engine settings
    /// exactly. A future on-device sweep replaces the entries
    /// marked `UNVERIFIED` with measured winners.
    private static func baseProfile(
        for config: LocalModelDownloadManager.ModelConfiguration
    ) -> LLMRuntimeProfile {
        var profile: LLMRuntimeProfile

        switch config {
        case .llama1b:
            // 4 GB tier (iPhone 11/12/13). A13 has 2 P-cores + 4 E-cores;
            // 2 threads keeps work on the P-cores (E-core spill hurts CPU
            // decode). n_ctx 1024 must match `fitToBudget`'s nCtx in the
            // memory hierarchy.
            // n_ctx 2048: the anchored history window
            // in LocalLLMMemoryHierarchy needs room to grow between jumps,
            // or it re-prefills every turn. q4_0 KV at 2048 is ~19 MB.
            profile = LLMRuntimeProfile(
                contextLength: 2048, threads: 2, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 0, pldNDraft: 0)
        case .llmJp3:
            // 4 GB tier, LLM-jp-3 1.8B Q3_K_M (~0.96 GB). Same conservative
            // 1024-ctx / 2-thread footprint as llama1b. PLD tuned for
            // Japanese (n=2, nDraft=3): JP subword 3-grams repeat less than
            // English, so the default window wastes batch-decode cycles.
            profile = LLMRuntimeProfile(
                contextLength: 1024, threads: 2, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 2, pldNDraft: 3)
        }

        return profile
    }

    /// Resolve the runtime profile for a model slot on the current device.
    ///
    /// Starts from the sweep-tuned `baseProfile(for:)` and layers on the
    /// device-dependent adjustments below (CPU-only fallback, thread cap,
    /// RAM-scaled context window).
    static func resolve(
        for config: LocalModelDownloadManager.ModelConfiguration
    ) -> LLMRuntimeProfile {
        var profile = baseProfile(for: config)

        #if targetEnvironment(simulator)
        profile = tuned(profile, ramGB: 0, isSimulator: true, gpuAllowed: false)
        #else
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        profile = tuned(profile, ramGB: gb, isSimulator: false, gpuAllowed: LLMGPUSentinel.gpuAllowed())
        nlLog("[LLMProfile] \(String(format: "%.1f", gb)) GB → gpuLayers=\(profile.gpuLayers) threads=\(profile.threads) kv=\(profile.kType.rawValue)",
              level: .info)
        #endif

        // Dynamic thread cap: the per-tier thread counts in `baseProfile` are
        // sweep-tuned (the larger tiers intentionally use E-cores), so they
        // are respected as-is. Only intervene when a tier value exceeds what
        // the silicon actually offers — per upstream llama.cpp guidance, more
        // threads than physical cores always hurts throughput. Apple silicon
        // has no SMT, so `processorCount` is the physical core count.
        let cores = Int32(ProcessInfo.processInfo.processorCount)
        if profile.threads > cores {
            let capped = max(2, cores)
            nlLog(
                "[LLMProfile] Thread count capped: \(profile.threads) → \(capped) (cores=\(cores))",
                level: .info)
            profile.threads = capped
        }

        // Thermal / Low Power Mode: a hot or power-saving phone gets at most
        // two generation threads (RuntimePressurePolicy). Read at load; the
        // bridge has no runtime thread switch.
        let tier = RuntimePressureMonitor.currentTier()
        if let cap = RuntimePressurePolicy.threadCap(tier), profile.threads > cap {
            nlLog("[LLMProfile] Thread count capped by pressure tier \(tier): \(profile.threads) → \(cap)", level: .info)
            profile.threads = cap
        }

        // Dynamic n_ctx: scale the context window up on devices with RAM
        // headroom so multi-turn conversations stay in-context longer before
        // LocalLLMFactExtractor compaction kicks in. Never lowers the
        // sweep-tuned baseline. `resolvedContextLength` is the single source
        // of truth shared with `LocalLLMMemoryHierarchy.nCtx(for:)` — the
        // budget compactor and the bridge must agree on KV capacity.
        let dynamicCtx = resolvedContextLength(for: config)
        if dynamicCtx != profile.contextLength {
            nlLog(
                "[LLMProfile] Dynamic n_ctx: \(profile.contextLength) → \(dynamicCtx)",
                level: .info)
            profile.contextLength = dynamicCtx
        }

        return applyDebugOverrides(profile)
    }

    /// Resolved `n_ctx` for `config` on this device — the sweep-tuned per-model
    /// baseline, raised (never lowered) on RAM tiers with headroom for a larger
    /// KV cache.
    ///
    /// `LocalLLMMemoryHierarchy.nCtx(for:)` delegates here so the prompt budget
    /// compactor can never disagree with the `contextLength` the engines pass
    /// to the bridge — a mismatch would over-evict (wasting the larger window)
    /// or under-evict (overflowing prefill).
    /// Per-device tuning:
    /// - Every real device offloads the model to Metal, the iPhone 11
    ///   included. Below 5 GB that used to be CPU-only — 2 threads,
    ///   sharing the CPU with streaming TTS — the main reason local replies
    ///   came out so much slower here. `gpuAllowed` is LLMGPUSentinel's
    ///   verdict: GPU loads that died twice in a row keep that build on the CPU.
    /// - 5 GB and up: 4 threads and a q8_0 KV cache.
    /// - The Simulator stays on the CPU.
    /// Pure, for tests.
    static func tuned(
        _ base: LLMRuntimeProfile, ramGB: Double, isSimulator: Bool, gpuAllowed: Bool
    ) -> LLMRuntimeProfile {
        var profile = base
        if isSimulator {
            profile.gpuLayers = 0
            return profile
        }
        profile.gpuLayers = gpuAllowed ? 999 : 0
        if ramGB >= 5.0 {
            profile.threads = max(profile.threads, 4)
            profile.kType = .q8_0
            profile.vType = .q8_0
        }
        return profile
    }

    static func resolvedContextLength(
        for config: LocalModelDownloadManager.ModelConfiguration
    ) -> Int32 {
        let baseline = baseProfile(for: config).contextLength
        #if targetEnvironment(simulator)
        return baseline
        #else
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let ramCtx: Int32
        switch gb {
        case ..<5.0:  ramCtx = 512    // 4 GB tier — the model's baseline governs via max()
        case ..<7.0:  ramCtx = 2_048  // 6 GB tier — Qwen-3B sweet spot
        default:      ramCtx = 4_096  // 8 GB tier — Qwen-7B / speculative path
        }
        return max(baseline, ramCtx)
        #endif
    }

    // MARK: - Debug sweep override

    /// In DEBUG builds only, lets a tester cycle KV-quant / flash-attn /
    /// threads from `UserDefaults` so a single build can run the whole sweep
    /// matrix without recompiling per config. No-op in release. Keys:
    ///   nl.sweep.kType / nl.sweep.vType — LlamaKVType raw (1=f16, 2=q4_0, 8=q8_0, …)
    ///   nl.sweep.flashAttn              — -1 auto / 0 disabled / 1 enabled
    ///   nl.sweep.threads               — positive thread count
    private static func applyDebugOverrides(
        _ profile: LLMRuntimeProfile
    ) -> LLMRuntimeProfile {
        #if DEBUG
        var p = profile
        let d = UserDefaults.standard
        if d.object(forKey: "nl.sweep.kType") != nil,
           let k = LlamaKVType(rawValue: Int32(d.integer(forKey: "nl.sweep.kType"))) {
            p.kType = k
        }
        if d.object(forKey: "nl.sweep.vType") != nil,
           let v = LlamaKVType(rawValue: Int32(d.integer(forKey: "nl.sweep.vType"))) {
            p.vType = v
        }
        if d.object(forKey: "nl.sweep.flashAttn") != nil,
           let f = FlashAttnMode(rawValue: Int32(d.integer(forKey: "nl.sweep.flashAttn"))) {
            p.flashAttn = f
        }
        if d.object(forKey: "nl.sweep.threads") != nil {
            let t = Int32(d.integer(forKey: "nl.sweep.threads"))
            if t > 0 { p.threads = t }
        }
        if p.kType != profile.kType || p.vType != profile.vType ||
            p.flashAttn != profile.flashAttn || p.threads != profile.threads {
            nlLog("[LLMProfile] DEBUG sweep override → kv=\(p.kType.rawValue)/\(p.vType.rawValue) fa=\(p.flashAttn.rawValue) threads=\(p.threads)",
                  level: .info)
        }
        return p
        #else
        return profile
        #endif
    }
}
