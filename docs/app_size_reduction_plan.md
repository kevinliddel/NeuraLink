# App Bundle Size Reduction Plan

> **Author:** Dedicatus
>
> **Drafted:** 2026-05-21
>
> **Scope:** App bundle composition only. No changes to LLM inference, audio, VRM rendering math, or any user-visible feature.

---

## 1. Goal

Reduce the installed app bundle from **~338 MB (Debug) / ~290 MB (Release estimated)** down to a **target band of 80–100 MB**.

Measured via Xcode's organizer / `du -sh NeuraLink.app` on the build output.

Target rationale: under 100 MB lets the app be downloaded over cellular without the iOS "large download" warning, and brings App Store install footprint into the same band as comparable voice-AI apps.

Out of scope: peak runtime RAM (covered by [local_llm_memory_plan.md](local_llm_memory_plan.md)), download speed of optional models (already on-demand), VRM render performance, model quality.

---

## 2. Inventory — where the bundle weight lives

> **Inventory aged out (2026-05-28).** The table below is from 2026-05-21, before VOICEVOX + Kokoro TTS engines landed. Re-measured 2026-05-28 on the Debug simulator bundle: total is **~1.4 GB**, dominated by **~830 MB of TTS data files** that didn't exist in the original inventory. Those are addressed in the new §4.5 below; the original §4.2 / §4.3 (scenes + characters) remain the right shape, just no longer the largest lever. The table is preserved as the pre-TTS picture.
>
> | Asset class added since 2026-05-21 | Files | Size | Cuttable? |
> |---|---|---:|---|
> | **VOICEVOX voice models** | `2.vvm`, `3.vvm`, `8.vvm`, `9.vvm`, `14.vvm`, `20.vvm` | **345 MB** | Yes — see §4.5 |
> | **Kokoro ONNX model** | `kokoro.onnx` | **328 MB** | Yes — see §4.5 |
> | **VOICEVOX Open JTalk dictionary** | `open_jtalk_dic_utf_8-1.11/` | **102 MB** | Yes — see §4.5 |
> | **Kokoro voice style table** | `voices.bin` | **51 MB** | Yes — see §4.5 |
> | **VOICEVOX ONNX Runtime framework** | `voicevox_onnxruntime.framework` | **25 MB** | No — needed for any JP TTS |
> | **Kokoro CMU pronunciation dictionary** | `cmu.txt` | **3.5 MB** | Yes — see §4.5 |
>
> TTS data alone (excluding the 30 MB of TTS frameworks that must stay resident) accounts for ~60% of today's bundle. After §4.5 lands, the bundle baseline drops back below the 2026-05-21 inventory, and §4.2 / §4.3 become the levers that complete the cut.

Captured 2026-05-21 from `Build/Products/Debug-iphoneos/NeuraLink.app`:

| Category | Files | Size | Cuttable? |
|---|---|---:|---|
| **Scene `.glb` assets** | `city.glb`, `campus.glb`, `tree.glb`, `grass.glb` | **201 MB** | Yes — move on-demand |
| Debug binary | `NeuraLink.debug.dylib` | 36 MB | Yes — Release strip drops to ~5–8 MB |
| **VRM characters** | `Sonya.vrm`, `Ekaterina.vrm` | **29 MB** | Yes — one bundled, rest on-demand |
| RealTimeCutVADCXXLibrary framework | (statically-linked ONNX Runtime) | 26 MB | Possibly — investigate arch slices |
| WebRTC framework | `WebRTC` | 11 MB | No — needed at launch for OpenAI realtime |
| llama framework | `llama` | 5 MB | No — needed at launch for local LLM |
| Silero VAD ONNX bundle | `silero_vad_v5.onnx`, `silero_vad.onnx` | 4 MB | No — VAD must run from launch |
| WhisperKit + ArgmaxCore + TTSKit + SpeakerKit | (frameworks) | 9 MB | No — small, all needed |
| `Assets.car`, `.vrma` animations, `.png` thumbnails, `default.metallib`, etc. | various | ~10 MB | No — fine |
| SQLCipher | (framework) | 1.4 MB | No |

**Five files account for 230 MB / 68% of the bundle.** That's where this plan focuses.

---

## 3. Scope boundaries

### In scope

| Layer | File(s) |
|---|---|
| Scene loaders | [VRMRenderer+City.swift](../NeuraLink/Core/Engine/VRM/Rendering/VRMRenderer+City.swift), [VRMRenderer+Campus.swift](../NeuraLink/Core/Engine/VRM/Rendering/VRMRenderer+Campus.swift) — the two `Bundle.main.url(forResource:withExtension:"glb")` call sites |
| Character registry | [ContentView.swift](../NeuraLink/App/ContentView.swift) — `VRMModelRegistry` enum (lines 127+) and the `selectedModelURL` state |
| Build settings | `NeuraLink.xcodeproj/project.pbxproj` — drop the four GLB files and one VRM from "Copy Bundle Resources" |
| New code | `NeuraLink/Data/DataSources/Assets/SceneAssetRegistry.swift`, `SceneAssetDownloader.swift`, `VRMCharacterDownloader.swift`, `RemoteAssetCache.swift` |
| First-launch UX | New view (under `Presentation/Views/Overlays/`) for progress + retry |

### Out of scope

- LLM inference, audio pipeline, VAD, WhisperKit, TTS — none touched.
- The `.vrma` animation files (~3 MB total) — too small to bother.
- Asset Catalog (`Assets.car` is already optimised at 2.6 MB).
- llama / WebRTC / WhisperKit framework binaries — already as small as they get without upstream changes.
- Default Ekaterina VRM stays bundled so first launch has a working avatar without network.

A failing assertion of this scope: if a change touches code outside the "In scope" list — and especially the inference or audio paths — it is mis-scoped.

---

## 4. Solution overview

Three concurrent levers, applied in order of risk:

### 4.1 Release build hygiene (zero code changes)

Verify and document Release build settings:

- `STRIP_INSTALLED_PRODUCT = YES`
- `DEAD_CODE_STRIPPING = YES`
- `SWIFT_OPTIMIZATION_LEVEL = -O`
- `GCC_OPTIMIZATION_LEVEL = s` (size, not speed — already default in Release)
- `LLVM_LTO = YES_THIN` (thin LTO)
- `ENABLE_BITCODE` — leave off (deprecated by Apple anyway)

Expected: `NeuraLink.debug.dylib` 36 MB → ~5–8 MB stripped Release binary. **Bundle: 338 → ~310 MB.**

### 4.2 On-demand scene downloads (the main lever)

The four GLB scene files total 201 MB. They are environment backgrounds — only one is active at a time. Move them to a remote repository and download on first selection. Pattern mirrors the existing [LocalModelDownloadManager](../NeuraLink/Data/DataSources/LocalModelDownloadManager.swift) GGUF flow:

- Storage: a HuggingFace dataset repo or any HTTPS bucket. URL + SHA-256 manifest baked into `SceneAssetRegistry`.
- Cache location: `Application Support/scenes/<id>.glb`.
- Loader: `VRMRenderer+City.swift:90` and `VRMRenderer+Campus.swift:89` currently do `Bundle.main.url(forResource:)`. Replace with `RemoteAssetCache.shared.url(for: .city)` — async; returns the cached file URL or downloads if missing.
- UX: a download progress overlay on first scene switch. Background download permitted via `URLSessionConfiguration.background` so the user can leave the app.
- Failure mode: if download fails, fall back to a tiny bundled "loading" scene (~1 MB plane + sky) so the avatar still has somewhere to stand. This stays bundled as a permanent safety net.

Expected: **Bundle: 310 → ~109 MB.** This is the only intervention that meaningfully shifts the needle.

### 4.3 On-demand character VRMs (cleanup pass)

Same pattern for `Sonya.vrm`. Default character (`Ekaterina.vrm`, 14 MB) stays bundled so first launch is always functional. `VRMModelRegistry.all` already enumerates characters — extend each entry with a remote URL and a `requiresDownload` flag; `selectedModelURL` becomes async/optional.

Expected: **Bundle: 109 → ~95 MB.** Lands in the 80–100 MB target band.

### 4.4 Investigate RealTimeCutVADCXXLibrary (26 MB)

Silero VAD's own ONNX models are 4 MB combined and live next to the framework. The framework being 26 MB suggests static-linked ONNX Runtime plus possibly dual arch slices. Investigations to run:

- `lipo -info` on `RealTimeCutVADCXXLibrary` — confirm only arm64 ships in Release (no x86_64 simulator slice).
- `nm -gU | wc -l` for symbol count — if it's tens of thousands, dead-strip may help.
- Check whether ORT can be configured to drop unused operators (microphone-VAD uses a tiny subset).

Worst-case outcome: no change. Best case: another 5–10 MB. Not required to hit target — strictly a bonus pass.

### 4.5 On-demand TTS assets (planned — separate future phase)

> **Status: planning only.** This section captures the inventory + strategy so it isn't lost; execution is deferred until the §4.2 / §4.3 work establishes the `RemoteAssetCache` infrastructure that this phase will reuse. No code change in this round.

The TTS engines added between 2026-05-21 and 2026-05-28 contributed **~830 MB of data files** that the 2026-05-21 inventory in §2 doesn't reflect. None of these need to ship inside the bundle — they map cleanly to the on-demand pattern §4.2 establishes for scenes.

Per-asset on-demand strategy:

| Asset | Size | Trigger to download | Cache location | Notes |
|---|---:|---|---|---|
| `kokoro.onnx` | 328 MB | First time English persona resolves to `KokoroEngine` AND user has explicitly enabled local LLM | `Application Support/tts/kokoro/kokoro.onnx` | One-time. ~13 MB int8 quant is a separate quality call — out of scope here |
| `voices.bin` | 51 MB | Same as `kokoro.onnx` (bundle-fetch together) | `Application Support/tts/kokoro/voices.bin` | Useless without `kokoro.onnx`; co-download |
| `cmu.txt` | 3.5 MB | Same as `kokoro.onnx` | `Application Support/tts/kokoro/cmu.txt` | Pronunciation dict — small but co-download for atomicity |
| `2.vvm` (Sonya/Dedicatus → Metan) | 56 MB | First time the persona resolves to that VOICEVOX speaker | `Application Support/tts/voicevox/<id>.vvm` | Per-speaker download; user owns the choice in PersonaSettings |
| `3.vvm` / `8.vvm` / `9.vvm` / `14.vvm` / `20.vvm` | ~57 MB each | Same — when the persona maps to that ID | `Application Support/tts/voicevox/<id>.vvm` | Average user only ever downloads 1–2 of the 6 |
| Open JTalk dict (`open_jtalk_dic_utf_8-1.11/`) | 102 MB | First time the user enables `.japaneseLlama1b` AND any VOICEVOX speaker resolves | `Application Support/tts/voicevox/open_jtalk_dic/` | Required for JP linguistic analysis; one-time per user. ~100 MB is unavoidable for the dict |

Expected reduction: **~830 MB → ~0 MB** of bundled TTS data. Combined with §4.2 / §4.3, that puts the bundle floor at the ~95 MB target with significant headroom.

Implementation notes (for the future phase):

- **Mirror §4.2's `RemoteAssetCache`.** Same pattern, same SHA-256 manifest, same first-launch overlay. The TTS phase only adds three new `Asset` enum cases and three downloader call-sites.
- **VVM-aware persona picker.** `PersonaSettingsView`'s voice picker today shows all 6 VOICEVOX speakers as instantly-selectable. After this phase, unselected speakers show a download badge (~57 MB) — same pattern as `ModelLibraryView` already uses for GGUFs.
- **First-use download UX.** Selecting a persona that needs a TTS asset triggers the download overlay; speech happens silently in the background using `SystemTTSEngine` until the download completes (per §3.1 of [local_llm_tts_plan.md](local_llm_tts_plan.md)'s fallback rule).
- **Hosting.** HF dataset repo same as scenes. VVMs are MIT-licensed redistributable; the bundled Kokoro ONNX is Apache-2.0; Open JTalk dict is BSD-style. No re-licensing risk.
- **Resume + integrity.** SHA-256 verify each asset after download — particularly important for `kokoro.onnx` because a truncated 328 MB file would fail to load with a cryptic ORT error.
- **Eager vs lazy in-memory.** Orthogonal to bundle size — covered separately in the TTS perf work (Kokoro slowness investigation). Bundle eviction here is purely about file-system bytes.

Risks specific to this phase:

| Risk | Mitigation |
|---|---|
| User on cellular installs the app, picks Japanese persona, eats 56 MB for the speaker plus 102 MB for JTalk dict in one go | Single combined progress overlay surfaces the 158 MB total up front, same warning shape as the GGUF model download flow today |
| First English speak with local LLM enabled hits a 379 MB download (kokoro + voices) before any audio plays | Detect offline / pre-download condition and fall back to `SystemTTSEngine` for that utterance; queue the Kokoro download in the background so subsequent turns use Kokoro |
| Removing 830 MB from "Copy Bundle Resources" must be done without breaking the existing `KokoroModelAccess` / `VoiceVoxModelAccess` path resolvers | Both classes already have a single source of truth for file paths; widen them to check `Application Support/tts/` first, fall through to `Bundle.main` second. Keeps the local dev flow (assets in source repo) working |

---

## 5. Phased plan

```mermaid
gantt
    title App Bundle Size Reduction
    dateFormat  YYYY-MM-DD
    axisFormat  %m-%d

    section Phase 0 — Plan review
    Plan drafted + approved                       :p0, 2026-05-21, 1d

    section Phase 1 — Release build hygiene
    Audit settings, document, measure baseline    :p1, after p0, 1d

    section Phase 2 — Asset hosting + manifest
    Upload GLBs to HF dataset, write SHA-256 manifest, registry  :p2, after p1, 1d

    section Phase 3 — Downloader infrastructure
    RemoteAssetCache + SceneAssetDownloader + tests             :p3, after p2, 2d

    section Phase 4 — Wire scene loaders
    VRMRenderer+City/Campus call-site swaps + first-launch UX   :p4, after p3, 2d

    section Phase 5 — Strip scene GLBs from bundle
    Drop from Copy Bundle Resources, smoke-test default scene   :p5, after p4, 1d

    section Phase 6 — Character VRM on-demand
    VRMCharacterDownloader, Sonya removed from bundle           :p6, after p5, 1d

    section Phase 7 — VAD framework investigation
    lipo / nm / ORT op-stripping (best-effort, may no-op)       :p7, after p6, 1d
```

Total active work: ~9 days excluding review. No external dependencies beyond uploading assets to a hosting bucket.

---

## 6. File-level map

### New files

| File | Lines (est.) | Purpose |
|---|---:|---|
| `Data/DataSources/Assets/SceneAssetRegistry.swift` | ~80 | Enum of remote scenes (`city`, `campus`, `tree`, `grass`) with URL + SHA-256 |
| `Data/DataSources/Assets/RemoteAssetCache.swift` | ~150 | Single-flight async URL resolver, on-disk cache, integrity verification |
| `Data/DataSources/Assets/SceneAssetDownloader.swift` | ~120 | Background `URLSession` download + progress reporting |
| `Data/DataSources/Assets/VRMCharacterDownloader.swift` | ~100 | Same as `SceneAssetDownloader` for `.vrm` files; thin wrapper |
| `Presentation/Views/Overlays/AssetDownloadOverlay.swift` | ~120 | Progress UI + retry / error states |

### Modified files

| File | Δ | Change |
|---|---|---|
| [VRMRenderer+City.swift](../NeuraLink/Core/Engine/VRM/Rendering/VRMRenderer+City.swift) | ~+10 | Replace `Bundle.main.url(...)` with async `RemoteAssetCache.url(for:)` |
| [VRMRenderer+Campus.swift](../NeuraLink/Core/Engine/VRM/Rendering/VRMRenderer+Campus.swift) | ~+10 | Same |
| [ContentView.swift](../NeuraLink/App/ContentView.swift) | ~+20 | `VRMModelRegistry.Entry` gains `remoteURL: URL?`; `selectedModelURL` resolves through `RemoteAssetCache` |
| `NeuraLink.xcodeproj/project.pbxproj` | small | Remove four `.glb` + one `.vrm` from synced bundle membership |

**Rule-7 verification (≤500 lines/file):** new files all ~150 lines or less; no modified file approaches the limit.

---

## 7. Validation

### Per-phase gates

1. `xcodebuild -scheme NeuraLink -destination "generic/platform=iOS"` — Release variant green.
2. `swiftlint lint --strict` — zero violations on touched files.
3. `du -sh NeuraLink.app` after each phase — record measurement. Must trend toward target.
4. On-device smoke test after Phase 4: first launch with no scenes cached, switch to each scene, verify download → render. Force-quit mid-download and retry to exercise the resume path.

### End-to-end acceptance (Phase 7)

| Check | Target |
|---|---|
| `du -sh NeuraLink.app` (Release) | **≤ 100 MB** |
| First-launch flow with no network | App opens, default Ekaterina avatar visible, "default" scene renders, scene picker shows "(download required)" badges |
| First scene download on cellular | Completes without iOS "large download" warning (the 200 MB warning threshold) |
| Existing functionality | Local LLM inference unchanged on iPhone 11; OpenAI realtime unchanged; VRM animation parity |

### Rollback plan

The bundled scene GLBs are simply re-added to Copy Bundle Resources. The `RemoteAssetCache` returns `Bundle.main.url(...)` as a first-check before going remote — so re-bundling is a single Xcode toggle, no code change. Worst-case revert: ~3 minutes.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Asset hosting cost / availability — bucket goes down or moves | Use HF datasets (free tier, well-known availability profile). Manifest in-code so we can swap the URL in one place. |
| First-launch UX feels broken if the only scene is downloaded | Bundle a tiny default scene (~1 MB plane + sky) so the avatar always has somewhere to stand. Reuse for offline-failure fallback. |
| User on cellular eats data — surprise 100 MB download | Gate non-default scene downloads behind an explicit user tap. Same pattern as the GGUF model picker in `ModelLibraryView` — never automatic. |
| Background download interrupted mid-flight | `URLSessionConfiguration.background` resumes automatically. SHA-256 manifest check catches truncated files. |
| GLB file integrity — bad CDN cache serving a corrupted file | SHA-256 verify after download; on mismatch, delete and re-attempt once before failing visibly. |
| App Store review flags large on-demand downloads | Apple's "App Thinning" + "On-Demand Resources" is the sanctioned mechanism. Investigate whether ODR could host the GLBs instead of a third-party bucket — gets Apple-side bandwidth and review-friendliness, at the cost of being App Store-only (no TestFlight off-line installs of new scene packs). |
| GLB compression (Draco/KTX2) might be needed to make downloads faster | Out of scope here. If 97 MB city.glb feels too slow to download on average user connection, a separate compression pass can be added. The bundle target is independent of download speed. |

---

## 9. Rules compliance checklist

| Rule | How this plan complies |
|---|---|
| 1. ≤500 lines/file | All new files ≤200 lines; no modified file approaches the limit. |
| 2. Clean Architecture | New code lives under `Data/DataSources/Assets/` — Data layer; depends only on Foundation + URLSession. No SwiftUI/Presentation references except the overlay view in `Presentation/Views/Overlays/`. |
| 5. Don't break what works | Bundle.main lookup remains as a first-check in `RemoteAssetCache.url(for:)` — if a developer still has the GLB locally, it loads instantly. All-or-nothing migration avoided. |
| 7. swiftlint --strict | Runs at end of each phase. |
| 12. Build succeeds | `xcodebuild` runs at the end of every phase. |

---

## 10. Out-of-scope follow-ups

Tracked here so they don't get lost:

0. **On-demand TTS assets (§4.5)** — planned future phase, ~830 MB potential reduction. Execution deferred until §4.2 / §4.3 land the `RemoteAssetCache` infrastructure this phase will reuse. Cross-reference: [local_llm_tts_plan.md](local_llm_tts_plan.md) §4 already anticipates `.vvm` downloads; this is the bundle-side counterpart.

1. **Draco mesh compression + KTX2 texture compression** on the GLB files. Typical 60–80% reduction. Would shrink download time (not bundle size, which is the focus here). Likely a Phase 8 if scene downloads feel too slow in practice.
2. **On-Demand Resources (Apple)** as a replacement for the third-party bucket. Apple-managed CDN, App Store-aware, but more setup and only works on App Store builds. Worth considering once we have a feel for the hosting cost on whichever bucket we pick.
3. **Lazy framework loading** for the OpenAI path (WebRTC at 11 MB) — only load WebRTC.framework when the user first selects OpenAI mode. Requires `dlopen` plumbing; complex enough to defer until 100 MB target isn't enough.
4. **Strip simulator slices from third-party `.xcframework`s** at archive time. Build setting `ONLY_ACTIVE_ARCH = YES` for Release usually handles this, but `RealTimeCutVADCXXLibrary` is suspiciously large and may not be honoring it — flagged for Phase 7 investigation.

---

## 11. Cross-references

- [local_llm_iphone11_plan.md](local_llm_iphone11_plan.md) — companion plan for runtime perf. App size is the other axis on the same device tier (4 GB RAM, limited storage on entry-level iPhones).
- [npu_migration.md](npu_migration.md) — historical precedent for moving heavy assets (CoreML model chunks → llama.cpp GGUF download) out of the bundle. Same pattern applied to scenes/VRMs here.
- [local_llm_tts_plan.md](local_llm_tts_plan.md) — the TTS plan explicitly notes ~107 MB Open JTalk dictionary + ~600 MB F5-TTS weights — both intended to download on demand. This plan establishes the infrastructure (`RemoteAssetCache`) that the TTS plan can reuse for its `.vvm` / `.onnx` / weight downloads.
