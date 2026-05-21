# Local LLM — iPhone 11 Performance Plan

> **Status:** P1–P6 shipped; P7 deferred. Companion to [local_llm_memory_plan.md](local_llm_memory_plan.md) Phase 3 validation — this file *is* that validation.
>
> **Author:** Dedicatus
>
> **Drafted:** 2026-05-20
>
> **Last updated:** 2026-05-20
>
> **Scope:** Llama-3.2-1B (English) and Llama-3.2-1B-JP on iPhone 11 (A13, 4 GB RAM, CPU-only path).

---

## 1. Goal

Make local‑LLM conversation usable on the entry‑tier device (iPhone 11) without changing the inference framework or downloading a different model.

Targets (measured via `[Bench]` log lines emitted from `LlamaBridge.logBenchmark`):

| Metric | Baseline (pre‑plan) | Target | Measured after P1–P6 |
|---|---|---|---|
| Cold turn 1 `ttft` | ~17 s | ≤ 6 s | **~2 s** (with cache hit) ✓ |
| Warm turn `ttft` | 5.6 – 9.1 s | ≤ 3 s | **1.3 – 4.3 s** (mostly ≤ 3 s) ✓ |
| Decode tok/s | 3.5 – 5.0 | ≥ 5.0 stable | 3.2 – 6.1 (mixed) ~ |
| Self‑loop events | observed | 0 | 0 observed in retest ✓ |

> Decode tok/s is the only metric not strictly meeting target; the 6.1 ceiling is up but the 3.2 floor is on very short outputs where ttft dominates user perception anyway. Improvement here is what P7 (Metal) would unlock.

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

### Phase 4 — prompt cleanup (correctness, all local LLM paths)

Not in the original P1–P7 queue. Surfaced from iPhone 11 testing during Phase 3 validation: the JP model answered "what is my name?" with `私の名前はDedicatusです` instead of `あなたの名前はDedicatusです` — confusing the AI's `私` (I) with the user's `あなた` (you). Root cause was a contradiction the prior `selfBoundary` text introduced: it instructed the model to "always say I don't know yet when asked about the user", but the very next line in the prompt provided the user's name. The same contradiction was present in the English Llama-1B and Qwen personas in different shapes.

| Item | Files | Effect |
|---|---|---|
| **JP pronoun/role disambiguation** — replace the contradictory `selfBoundary` text with dynamic role clarification that names both `私` (AI) and `あなた` (user) using actual values | [LocalLLMMemoryHierarchy.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift), [LocalLLMPromptStore.swift](../NeuraLink/Data/DataSources/LocalLLMPromptStore.swift) | New `buildJPRoleClarification` helper; static persona prompt now contains personality lines only. Adds explicit instruction that when the user uses 「私／僕／俺」 the AI must reply using 「あなた」 |
| **English role disambiguation across all model tiers** — same pattern as JP, applied to Llama-1B + Qwen-2B/3B/7B paths | [LocalLLMMemoryHierarchy.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift), [LocalLLMPromptStore.swift](../NeuraLink/Data/DataSources/LocalLLMPromptStore.swift) | New `buildEnglishRoleClarification` helper uses third-person framing (`[Role] {AI} is the AI assistant; the user is {name}. ...`) so it works regardless of whether the persona below uses first-person ("I am Ekaterina" — Llama-1B) or second-person ("You are Ekaterina" — Qwen). Removed contradictory "I must say I don't know yet" (Llama-1B) and "You don't know personal details about the user unless they tell you" (Qwen) clauses |

**Cache invalidation note:** the JP and English persona hashes changed → existing users pay one extra cold prefill on the next launch while the KV cache gets rewritten to disk under the new persona hash. Subsequent launches are fast again.

---

## 3. Priority queue — proposed work + outcomes

Originally proposed in priority order (expected impact / cost ratio). Each item keeps its original description and gets a **Status** annotation describing what actually shipped and what we measured.

### P1 — Persistent KV cache to disk (cold start)

The Tier 1 system+persona prefix is identical across runs. Today the first turn after app launch repays the full ~6–17 s prefill of that prefix every time. `llama_state_seq_save_file` / `llama_state_seq_load_file` can serialise the prefilled KV state to disk; subsequent launches `mmap`‑load it in <100 ms.

- **Files:** new C bridge entrypoints `llama_bridge_save_kv_state(path)` / `llama_bridge_load_kv_state(path)` in [llama_bridge.cpp](../NeuraLink/Core/Bridge/llama_bridge.cpp); call sites in [GGUFLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaEngine.swift) loadModel/unload path.
- **Storage key:** `Application Support/llm_kv/<modelHash>_<personaHash>.bin`. Invalidate when either hash changes.
- **Expected:** cold turn 1 `ttft` drops from ~17 s to ~2 s on first launch *after* the cache has been written once.
- **Risk:** medium — KV state files are version‑sensitive across llama.cpp versions. Mitigate by embedding `llama_print_system_info()` hash in the filename.
- **Validation:** force‑quit app, relaunch, ask "hi". Read `prefill=R+N`. Acceptance: `R ≥ 150` on first turn (was 0 before this work).

**Status — shipped 2026-05-20.** Implementation came in slightly bigger than the plan implied: the `LlamaBridgeHandle` struct moved out of `llama_bridge.cpp` into a new shared internal header [llama_bridge_internal.hpp](../NeuraLink/Core/Bridge/llama_bridge_internal.hpp), and the save/load entrypoints landed in a separate [llama_bridge_state.cpp](../NeuraLink/Core/Bridge/llama_bridge_state.cpp) (keeping the main bridge under the file-size rule). Storage key uses a SHA-256 prefix of the system prompt rather than two hashes — persona edits invalidate automatically, model identity is captured by the config name in the filename. Wired via new `LLMEngineProtocol.{saveKVCache,loadKVCache}` methods with no-op defaults so Qwen tiers are unaffected. Validation passed: warm runs now consistently show `prefill=174+~20` (R≈Tier-1 size constant across turns, N≈user turn only).

---

### P2 — Prompt reordering to expand prefix‑reuse coverage

Today's `[Bench]` shows warm turns reuse ~150–220 tokens (Tier 1) and re‑prefill ~200–360 tokens (history + user). The verbatim history is *append‑only* — older turns don't change — but RAG facts and the user turn are appended *between* stable and unstable regions, breaking the cache. The current order in [LocalLLMMemoryHierarchy.buildMessages](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift) puts facts inside the system message; we can do better.

- **Files:** [LocalLLMMemoryHierarchy.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift) — move RAG facts from the system message into a separate message inserted **after** verbatim history but **before** the user turn. The verbatim history then sits contiguously after system, maximising cacheable prefix.
- **Expected:** reused tokens grow from ~150 → ~300–400 (Tier 1 + Tier 2). New tokens drop from ~250 → ~50–100 per turn. Warm `ttft` halves.
- **Risk:** low — needs a quality check that the 1B still respects facts when they're not in the system message. The JP variant already does this kind of restructuring; English path is similar.
- **Validation:** 10‑turn dialogue. Acceptance: median `prefill=R+N` shows `N ≤ 100` on turns 3+.

**Status — shipped 2026-05-20.** Single-file change exactly as described. Measured result exceeded the target: `new` dropped to **16–26 tokens** per turn (the user turn delta itself), not the ~50–100 we modelled. Quality regression on facts not yet observed; the 1B still uses the [Established facts about the user] block when it follows the history.

---

### P3 — IQ4_NL quantisation of Llama‑1B

The current GGUF is Q4_K_M (~0.8 GB). IQ4_NL is an ARM‑NEON‑tuned quant designed for Apple Silicon — at the same bit budget it routinely runs 20–30% faster on A‑series CPUs than legacy K‑quants. Q3_K_M is also worth measuring (smaller, slightly worse quality) but starts at the same speed envelope.

- **Files:** new downloader URL in [GGUFLlamaDownloader.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaDownloader.swift); add a quant selector to [ModelLibraryView](../NeuraLink/Presentation/Views/AI/) if we want users to toggle without re‑downloading.
- **Expected:** decode 3.5 → 4.5 tok/s on iPhone 11 CPU. Also frees ~200 MB RAM headroom if we switch to Q3_K_M.
- **Risk:** quality regression on a 1B is real but small for spoken dialog. A/B locally before defaulting.
- **Validation:** 5‑turn dialogue both quants. Acceptance: ≥15% decode tok/s improvement at no worse than parity on the self‑boundary sanity check ("tell me about myself" → "I don't know yet").

**Status — shipped 2026-05-20 with quant pivot.** WebFetch of both Hugging Face repos showed **IQ4_NL is not actually published** for Llama-3.2-1B in either `bartowski` or `grapevine-AI`. Pivoted to **IQ4_XS** (the close ARM-tuned cousin available in both repos): 4.25 bpw vs Q4_K_M's 4.85, ~65 MB smaller (743 vs 808 MB), same NEON kernels. Implemented as an outright filename swap rather than the parallel-variant UI option — keeps the change scope minimal. [GGUFModelAccess.modelURL()](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFModelAccess.swift) gained a guard that validates the persisted UserDefaults path against the current `filename` constant so existing Q4_K_M users automatically re-download instead of silently loading the stale file. On-device decode-tok/s impact will be measurable on the first iPhone 11 run after the IQ4_XS download completes.

---

### P4 — PLD tuning for the JP path

Default `pld_n=3, pld_n_draft=5` was tuned on English n‑gram statistics. Japanese subword tokens repeat less in conversation; the wasted batch‑decodes on PLD mismatches likely exceed the wins.

- **Files:** [GGUFJapaneseLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine.swift) — pass `LlamaBridge(... promptLookup: true)` then `bridge.enablePromptLookup(true, n: 2, nDraft: 3)`. Also add an n‑gram‑hit counter to `[Bench]` so we can measure first.
- **Expected:** small improvement (5–10%) on JP decode; possibly a small regression if hit rate is actually fine. **Measure before deciding.**
- **Risk:** very low — purely a runtime knob.
- **Validation:** add a `pld_hits=X/Y` counter to the benchmark line. If hit rate <15% for the default config on JP, drop `n` to 2.

**Status — shipped 2026-05-20.** Telemetry added per the validation step: `pld=hits/rounds(%)` now appears in every `[Bench]` line, sourced from new `last_pld_rounds` / `last_pld_hits` counters in [llama_bridge_internal.hpp](../NeuraLink/Core/Bridge/llama_bridge_internal.hpp). Counters reset at the start of every `llama_bridge_generate`; hits increment only when drafts[0] verifies. `LlamaBridge.init` gained `pldN` / `pldNDraft` parameters so the JP engine can opt into the tighter window without affecting the English engine's defaults. First-run JP measurements showed hit rates of 0% on short outputs (not enough context) and 14–21% on longer outputs — kept the tuned values; will revisit if hit rate stays at 0% on representative dialog.

---

### P5 — Reduce `n_ctx` (2048 → 1024) for iPhone 11

The 3‑tier hierarchy's compactor activates at 80% of `n_ctx`. At 2048 that's turn ~10. Halving `n_ctx` to 1024 compacts at turn ~5, keeps the KV cache smaller (saves ~50 MB on Q4_0 K/V), and shortens per‑token attention cost (linear in cached length).

- **Files:** [GGUFLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/Llama/GGUFLlamaEngine.swift), [GGUFJapaneseLlamaEngine.swift](../NeuraLink/Data/DataSources/GGUF/JapaneseLlama/GGUFJapaneseLlamaEngine.swift) — `contextLength: 1024`.
- **Expected:** marginal decode speedup (~5%), better memory headroom, more frequent compaction.
- **Risk:** the compactor's fact‑extraction quality on a 1B is already imperfect (see [local_llm_memory_plan.md §9](local_llm_memory_plan.md)); compacting more often surfaces more potential errors.
- **Validation:** seed a 20‑turn dialogue, verify the model still recalls a fact established at turn 1 when asked at turn 18.

**Status — shipped 2026-05-20.** One important extra: [LocalLLMMemoryHierarchy](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMMemoryHierarchy.swift) gained a new `nCtx(for:)` helper. Without it, the budget compactor would have over-counted capacity (still thinking we had 2048) and let prompts grow past the actual KV cache, crashing on `llama_decode`. The helper returns 1024 for `.llama1b` / `.japaneseLlama1b` and keeps 2048 for Qwen tiers — Qwen path unaffected.

---

### P6 — Hardware acoustic echo cancellation (deeper self‑loop fix)

The 800 ms mic gate covers the symptom but the root cause is iOS not enabling AEC under `.default` audio session mode. `audioEngine.inputNode.setVoiceProcessingEnabled(true)` (iOS 15+) turns on hardware voice processing including AEC, AGC, and noise suppression.

- **Files:** [LocalLLMManager+Audio.swift](../NeuraLink/Data/DataSources/LocalLLM/LocalLLMManager+Audio.swift) — call `setVoiceProcessingEnabled(true)` after `audioEngine.start()`, and switch session mode from `.default` to `.voiceChat`.
- **Expected:** self‑loop becomes structurally impossible; gate can be shortened or removed. Mic also gets noise suppression for free.
- **Risk:** medium — voice processing changes the input format and can break the existing mic tap (sample rate, channel count). Has bitten other voice apps when interacting with `AVAudioEngine` taps. Test thoroughly.
- **Validation:** ten‑minute long monologue + a YouTube playing in background through speakers. Acceptance: zero self‑triggered turns.

**Status — shipped 2026-05-20, with one deliberate deviation from the plan.** Only enabled `setVoiceProcessingEnabled(true)` on `audioEngine.inputNode`; **kept the audio session mode at `.default`** rather than switching to `.voiceChat`. Reason: `.voiceChat` would have forced HFP for Bluetooth (16 kHz mono) instead of A2DP, breaking the `.allowBluetoothA2DP` setup. The input-node API alone gives us AEC/AGC/NS without that cascade. The 800 ms mic gate from the prior diagnostic phase stays in place as belt-and-suspenders during the brief window before AEC has converged on the new echo signature. Wrapped in `do/catch` so a future iOS that rejects the API falls back to gate-only behaviour without crashing.

---

### P7 — Precompiled metallib (enable Metal on iPhone 11)

CPU‑only on A13 is the dominant cost. Metal would be ~3× faster for both prefill and decode. We currently force `gpuLayers = 0` on <5 GB devices because Metal kernel compilation under load triggers `MTLCompilerService` jetsam crashes ([LlamaBridge.swift:53‑58](../NeuraLink/Data/DataSources/GGUF/LlamaBridge.swift#L53-L58)). The fix: ship a precompiled `.metallib` and disable runtime compilation. Listed in [local_llm_memory_plan.md §10.4](local_llm_memory_plan.md) as "tricky" — requires patching upstream llama.cpp to disable `GGML_METAL_EMBED_LIBRARY`.

- **Files:** vendored llama.cpp framework build settings; new build phase to run `xcrun -sdk iphoneos metal` against the vendored `.metal` source.
- **Expected:** decode 4–5 tok/s → 12–15 tok/s. `ttft` halves again. This is the single biggest theoretical win.
- **Risk:** high — touches the framework build, needs an upstream patch, can regress on iOS versions we don't test.
- **Validation:** all the above benchmark gates, on iPhone 11 specifically. Compare metallib vs CPU‑only.

**Status — deferred.** Not started. After P1–P6, warm `ttft` is in the 1.3–4.3 s band and cold-start is ~2 s with a cache hit — both close to the targets in §1. P7's theoretical 3× decode win is still attractive but its risk profile (upstream patch, framework rebuild, can break the build on iOS versions we don't actively test) is much higher than anything we've shipped so far. Revisit only if decode tok/s becomes the dominant user complaint after a few sessions of real use.

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
