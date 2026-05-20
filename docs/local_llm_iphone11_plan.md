# Local LLM — iPhone 11 Performance Plan

> **Status:** In progress. Companion to [local_llm_memory_plan.md](local_llm_memory_plan.md) Phase 3 validation.
> **Author:** Dedicatus
> **Drafted:** 2026-05-20
> **Scope:** Llama-3.2-1B (English) and Llama-3.2-1B-JP on iPhone 11 (A13, 4 GB RAM, CPU-only path).

---

## 1. Goal

Make local‑LLM conversation usable on the entry‑tier device (iPhone 11) without changing the inference framework or downloading a different model.

Targets (measured via `[Bench]` log lines emitted from `LlamaBridge.logBenchmark`):

| Metric | Today (post‑Phase 1) | Target |
|---|---|---|
| Cold turn 1 `ttft` | ~17 s | ≤ 6 s |
| Warm turn `ttft` | 5.6 – 9.1 s | ≤ 3 s |
| Decode tok/s | 3.5 – 5.0 | ≥ 5.0 stable |
| Self‑loop events | observed | 0 |

Out of scope here: Qwen‑3B / Qwen‑7B tuning (those are RAM‑bound on iPhone 11 and a separate problem), cloud realtime path, VRM rendering.

---

## 2. Already shipped (Phase 1 + 2)

Recorded so this plan doesn't double‑count completed work.

### Phase 1 — diagnostic + cheap wins

| Item | Files | Effect |
|---|---|---|
| Per‑call benchmark logging (`ttft / decode / prefill=R+N`) | [LlamaBridge.swift](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift), [llama_bridge.cpp](../NeuraLink/Core/Bridge/llama_bridge.cpp) | Measurement plumbing — required for everything below |
| `threads = 4 → 2` (A13 P‑core pinning) | [GGUFLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaEngine.swift), [GGUFJapaneseLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine.swift) | Decode floor lifted from ~2 tok/s to ~3.5 tok/s; less variance on long outputs |
| Background prefill warmup on VAD voice‑start + cold‑start | [LocalLLMManager.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager.swift), [LocalLLMManager+VAD.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+VAD.swift), [LlamaBridge.swift](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift), [llama_bridge.cpp](../NeuraLink/Core/Bridge/llama_bridge.cpp) | Hides sys+persona+history prefill behind user speech — final `generate` only re‑prefills the user‑turn delta |
| `maxNewTokens` for English Llama‑1B: 100 → 60 | [LocalLLMManager.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager.swift) | Caps spoken responses to a realistic length at 4 tok/s |
| Self‑boundary system prompt for Llama‑1B (matches JP fix) | [LocalLLMPromptStore.swift](../NeuraLink/Data/DataSources/LocalLLMPromptStore.swift) | Reduces hallucination where the 1B reads its own persona back as user attributes |
| Mic‑to‑VAD gate during AI speech + 800 ms cool‑down | [LocalLLMManager+Audio.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+Audio.swift) | Eliminates the self‑loop where speaker leak triggered VAD as user input (observed on Llama‑1B + Qwen‑7B) |

### Phase 2 — structural changes (Llama paths only)

| Item | Files | Effect |
|---|---|---|
| **P2: Prompt reordering** — RAG facts moved out of the system message into a separate message after history | [LocalLLMMemoryHierarchy.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift) | Keeps `[system + history]` contiguous and stable across turns; only the per‑turn facts block + user turn need re‑prefilling. Expected: warm `prefill=R+N` shifts from ~150/250 toward ~300/100 |
| **P1: Persistent KV cache to disk** — save once per session, restore on cold start | new [llama_bridge_internal.hpp](../NeuraLink/Core/Bridge/llama_bridge_internal.hpp), new [llama_bridge_state.cpp](../NeuraLink/Core/Bridge/llama_bridge_state.cpp), [llama_bridge.h](../NeuraLink/Core/Bridge/llama_bridge.h), [LlamaBridge.swift](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift), [LLMEngineProtocol.swift](../NeuraLink/Domain/Interfaces/LLMEngineProtocol.swift), [GGUFLlamaEngine+Generate.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaEngine+Generate.swift), [GGUFJapaneseLlamaEngine+Generate.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine+Generate.swift), new [LocalLLMKVCache.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMKVCache.swift), [LocalLLMManager.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager.swift) | Cache file at `Application Support/llm_kv/<config>_<personaHash>.kv`. Cold turn 1 `ttft` expected to drop from ~17 s to <1 s on the second-and-later launches. Persona edits invalidate the cache automatically via the prompt hash in the filename. Limited to `.llama1b` and `.japaneseLlama1b` for now — Qwen tiers will get their own plan |

### Phase 3 — measurement + memory shaping + AEC (Llama paths only)

| Item | Files | Effect |
|---|---|---|
| **P5: `n_ctx` 2048 → 1024** | [GGUFLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaEngine.swift), [GGUFJapaneseLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine.swift), [LocalLLMMemoryHierarchy.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift) | Halves the KV cache (saves ~50 MB RSS on iPhone 11), shortens per-token attention. New `nCtx(for:)` in hierarchy keeps compactor in sync with actual capacity. Qwen tiers unaffected — they stay at 2048 |
| **P4: PLD telemetry + JP tuning** — `pld=hits/rounds(%)` now in `[Bench]`; JP uses `n=2, nDraft=3` | [llama_bridge_internal.hpp](../NeuraLink/Core/Bridge/llama_bridge_internal.hpp), [llama_bridge.cpp](../NeuraLink/Core/Bridge/llama_bridge.cpp), [llama_bridge_state.cpp](../NeuraLink/Core/Bridge/llama_bridge_state.cpp), [llama_bridge.h](../NeuraLink/Core/Bridge/llama_bridge.h), [LlamaBridge.swift](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift), [GGUFJapaneseLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine.swift) | First time we can actually measure whether PLD is worth keeping per-language. JP gets a tighter window because subword n-grams repeat less in Japanese than English |
| **P6: Hardware AEC via voice processing** | [LocalLLMManager+Audio.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+Audio.swift) | `setVoiceProcessingEnabled(true)` on the input node before any taps install. Structural fix for speaker-to-mic leakage. The 800 ms mic gate cool-down stays as belt-and-suspenders for the AEC convergence window |
| **P3: IQ4_NL → IQ4_XS quant swap** (IQ4_NL not in either repo; IQ4_XS is the available ARM-tuned alternative) | [GGUFModelAccess.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFModelAccess.swift), [GGUFJapaneseLlamaModelAccess.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaModelAccess.swift), [GGUFLlamaDownloader.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaDownloader.swift), [GGUFJapaneseLlamaDownloader.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaDownloader.swift), [LocalModelDownloadManager.swift](../NeuraLink/Data/DataSources/LocalModelDownloadManager.swift) | Filename swap (Q4_K_M → IQ4_XS), ~65 MB smaller, ARM-NEON tuned. `modelURL()` now validates the persisted UserDefaults path against the current `filename` so existing users automatically re-download instead of silently loading the stale Q4_K_M file |

---

## 3. Priority queue — remaining work

Ordered by **expected impact / cost ratio**. Items are independent unless noted.

> P1, P2, P3, P4, P5, P6 have moved to §2 as shipped. The only remaining item is P7 (precompiled metallib), which is high-risk / high-effort and not yet started.

### P7 — Precompiled metallib (enable Metal on iPhone 11)

CPU‑only on A13 is the dominant cost. Metal would be ~3× faster for both prefill and decode. We currently force `gpuLayers = 0` on <5 GB devices because Metal kernel compilation under load triggers `MTLCompilerService` jetsam crashes ([LlamaBridge.swift:53‑58](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift#L53-L58)). The fix: ship a precompiled `.metallib` and disable runtime compilation. Listed in [local_llm_memory_plan.md §10.4](local_llm_memory_plan.md) as "tricky" — requires patching upstream llama.cpp to disable `GGML_METAL_EMBED_LIBRARY`.

- **Files:** vendored llama.cpp framework build settings; new build phase to run `xcrun -sdk iphoneos metal` against the vendored `.metal` source.
- **Expected:** decode 4–5 tok/s → 12–15 tok/s. `ttft` halves again. This is the single biggest theoretical win.
- **Risk:** high — touches the framework build, needs an upstream patch, can regress on iOS versions we don't test.
- **Validation:** all the above benchmark gates, on iPhone 11 specifically. Compare metallib vs CPU‑only.

---

## 4. Validation protocol

Same measurement harness across every item — the `[Bench]` log line emitted from [LlamaBridge.logBenchmark](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift).

For each change:

1. **Baseline:** run a 5‑turn scripted dialogue on iPhone 11, both Llama‑1B (English) and Llama‑1B‑JP. Capture median `ttft` and `decode` of turns 2–5 (skip turn 1 — cold).
2. **Change:** apply the single item under test.
3. **Re‑measure:** same scripted dialogue.
4. **Decision:** keep if the change clears the item's "Expected" target without making any other metric worse. If a tradeoff is required, document it inline in this file.

Scripted dialogue (cover persona, recall, refusal):

```
Turn 1: Hi.
Turn 2: What's your name?
Turn 3: I just got a cat named Mochi.
Turn 4: Tell me about myself.            <- must refuse / "I don't know yet"
Turn 5: What's my cat's name?            <- must recall after turn 6+ when compacted
```

---

## 5. Out‑of‑scope follow‑ups

Tracked here so they don't get lost:

- **Qwen‑3B / Qwen‑7B on 4 GB devices:** prefill drops to ~6 tok/s and decode to 0.05 tok/s due to swap — fundamentally RAM‑bound. Hard‑gating in `ModelLibraryView` is one option; another is letting users opt in with a strong warning. User has indicated they want to keep models accessible for experimentation, so no gate for now.
- **Speculative engine prefill API:** current `prefill(messages:)` is a no‑op for `GGUFSpeculativeEngine` because it uses a different bridge. Add when iPhone 15 Pro tier tuning becomes a priority.
- **Reduce TTS latency:** if decode tok/s improves enough to where the user perceives TTS lag rather than LLM lag, look at the sentence‑chunker thresholds in [LocalLLMManager+Engine.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+Engine.swift).

---

## 6. Cross‑references

- [local_llm_memory_plan.md](local_llm_memory_plan.md) — the parent plan; this file extends Phase 3 (validation) with device‑specific tuning.
- [npu.md](npu.md) — engine routing matrix and supported SLMs.
- [npu_migration.md](npu_migration.md) — CoreML → llama.cpp migration history (context for why we're CPU‑only on A13).
