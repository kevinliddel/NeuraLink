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

    /// Resolve the runtime profile for a model slot on the current device.
    ///
    /// Base values below reproduce the pre-refactor hardcoded engine settings
    /// exactly. The device sweep (see docs / plan Phase 3) replaces the entries
    /// marked `UNVERIFIED` with measured winners.
    static func resolve(
        for config: LocalModelDownloadManager.ModelConfiguration
    ) -> LLMRuntimeProfile {
        var profile: LLMRuntimeProfile

        switch config {
        case .llama1b:
            // 4 GB tier (iPhone 11/12/13). A13 has 2 P-cores + 4 E-cores;
            // 2 threads keeps work on the P-cores (E-core spill hurts CPU
            // decode). n_ctx 1024 must match `fitToBudget`'s nCtx in the
            // memory hierarchy.
            profile = LLMRuntimeProfile(
                contextLength: 1024, threads: 2, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 0, pldNDraft: 0)
        case .japaneseGemma2b:
            // 4 GB tier, Gemma 2 2B Q4_K_M (~1.71 GB). Same conservative
            // 1024-ctx / 2-thread footprint as llama1b. PLD tuned for
            // Japanese (n=2, nDraft=3): JP subword 3-grams repeat less than
            // English, so the default window wastes batch-decode cycles.
            profile = LLMRuntimeProfile(
                contextLength: 1024, threads: 2, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 2, pldNDraft: 3)
        case .qwen2b:
            // 6 GB tier.
            profile = LLMRuntimeProfile(
                contextLength: 2048, threads: 4, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 0, pldNDraft: 0)
        case .qwen3b:
            // 6 GB tier.
            profile = LLMRuntimeProfile(
                contextLength: 2048, threads: 4, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 0, pldNDraft: 0)
        case .qwen7b:
            // 8 GB tier (also the speculative target). KV settings apply to
            // both the target and draft contexts via the speculative bridge.
            profile = LLMRuntimeProfile(
                contextLength: 2048, threads: 6, gpuLayers: 999,
                kType: .q4_0, vType: .q4_0, flashAttn: .enabled,
                pldN: 0, pldNDraft: 0)
        }

        // Proactive CPU-only fallback (moved here from LlamaBridge so the tier
        // model owns it): the Simulator and < 5 GB devices (iPhone 11/12/13)
        // can't compile Metal shaders without risking jetsam, so force
        // gpuLayers = 0. The bridges keep a *reactive* retry-on-failure for
        // real Metal init errors on the GPU path. Flash-attn + KV are left
        // unchanged here (Phase-2 parity); the sweep decides whether the CPU
        // path prefers FA AUTO / f16 V.
        #if targetEnvironment(simulator)
        profile.gpuLayers = 0
        #else
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb < 5.0 {
            nlLog("[LLMProfile] Device RAM (\(String(format: "%.1f", gb)) GB) < 5.0 GB — CPU-only (gpuLayers = 0).",
                  level: .info)
            profile.gpuLayers = 0
        }
        #endif

        // Dynamic thread count: use physical performance-core count rather than
        // a fixed magic number. `processorCount` returns logical threads on Apple
        // silicon (P + E cores); dividing by 2 gives a conservative P-core
        // estimate that avoids spilling decode work onto E-cores. Clamped to
        // [2, 6] to match pre-sweep hand-tuned values on iPhone 11–16.
        let physicalCores = ProcessInfo.processInfo.processorCount
        let dynamicThreads = Int32(max(2, min(physicalCores / 2, 6)))
        // Only override the per-model baseline if the detected count differs —
        // logs clearly which source won so the sweep log stays readable.
        if dynamicThreads != profile.threads {
            nlLog(
                "[LLMProfile] Dynamic thread count: \(profile.threads) → \(dynamicThreads) (cores=\(physicalCores))",
                level: .info)
            profile.threads = dynamicThreads
        }

        // Dynamic n_ctx: scale context window by available RAM so multi-turn
        // conversations stay in-context longer before LocalLLMFactExtractor
        // compaction kicks in. Values are conservative to keep KV-cache RAM
        // well within the device's jetsam budget alongside the model weights.
        #if !targetEnvironment(simulator)
        let dynamicCtx: Int32
        switch gb {
        case ..<5.0:  dynamicCtx = 512   // Llama-1B / Gemma-2B safe budget
        case ..<7.0:  dynamicCtx = 2048  // Qwen-3B sweet spot
        default:      dynamicCtx = 4096  // Qwen-7B / speculative path
        }
        if dynamicCtx != profile.contextLength {
            nlLog(
                "[LLMProfile] Dynamic n_ctx: \(profile.contextLength) → \(dynamicCtx) (RAM=\(String(format: "%.1f", gb)) GB)",
                level: .info)
            profile.contextLength = dynamicCtx
        }
        #endif

        return applyDebugOverrides(profile)
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
