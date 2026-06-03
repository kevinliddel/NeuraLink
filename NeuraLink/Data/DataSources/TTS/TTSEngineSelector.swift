//
//  TTSEngineSelector.swift
//  NeuraLink
//
//  Orchestrates which TTSEngineProtocol implementation is used for a given
//  persona on the current device. Mirrors the role that
//  LocalLLMManager.makeEngine() plays for LLM engines.
//
//  Selection rules per docs/local_llm_tts_plan.md §3.1:
//    1. F5-TTS clone trained AND .qwen7b tier             -> F5TTSEngine
//    2. .japaneseGemma2b active                           -> VoiceVoxEngine
//    3. Kokoro voices downloaded                          -> KokoroEngine (deferred, returns nil)
//    4. Else                                              -> SystemTTSEngine
//
//  Engine selection is automatic — the user-facing voice picker in
//  PersonaSettingsView only chooses WHICH VOICEVOX speaker the persona
//  uses (stored in PersonaVoiceStore, consulted by `VoiceVoxSpeaker
//  .speakerID(for:)`).
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation

@MainActor
final class TTSEngineSelector {

    static let shared = TTSEngineSelector()

    private var cachedEngines: [PersonaIdentifier: any TTSEngineProtocol] = [:]

    private init() {}

    func engine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        if let cached = cachedEngines[persona] {
            return cached
        }

        guard let resolved = resolveEngine(for: persona) else {
            return nil
        }

        cachedEngines[persona] = resolved
        return resolved
    }

    func invalidateCache() {
        let engines = Array(cachedEngines.values)
        cachedEngines.removeAll()
        // `shutdown()` on VOICEVOX/Kokoro does `queue.sync { … }`. Calling
        // that from the MainActor while the queue is mid-synthesis blocks
        // the main thread and trips the iOS watchdog (SIGABRT on Thread 43).
        // The engines are singletons that don't actually need a tear-down to
        // re-key their persona — and a save-during-chat is the realistic
        // case here. So fire the stop on main (it's cheap / no-op for these
        // engines) and let the shutdown happen off-main if anything actually
        // needs it.
        for engine in engines {
            engine.stop()
        }
    }

    func invalidateCache(for persona: PersonaIdentifier) {
        guard let engine = cachedEngines.removeValue(forKey: persona) else { return }
        // Same rationale as `invalidateCache()` above — never block main on
        // `queue.sync`. The cached entry being removed is the actual contract
        // of "invalidate"; the engine's lifecycle is independent.
        engine.stop()
    }

    private func resolveEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        let config = LocalModelDownloadManager.shared.selectedConfig

        if hasTrainedClone(for: persona), config == .qwen7b {
            return makeF5TTSEngine(for: persona)
        }

        if config == .japaneseGemma2b {
            return makeVoiceVoxEngine(for: persona)
        }

        if hasKokoroVoicesDownloaded() {
            return makeKokoroEngine(for: persona)
        }

        return makeSystemTTSEngine(for: persona)
    }

    private func hasTrainedClone(for persona: PersonaIdentifier) -> Bool {
        CloneSampleStore.shared.url(for: persona) != nil
    }

    private func hasKokoroVoicesDownloaded() -> Bool {
        KokoroModelAccess.isAvailable
    }

    private func makeF5TTSEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        _ = persona
        return F5TTSEngine()
    }

    private func makeVoiceVoxEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        // Returns the shared engine in its current state. The caller is
        // responsible for awaiting `initialize()` before the first `speak`
        // call — engine.speak() throws .notInitialized otherwise. Wiring
        // happens in Phase 5 (`LocalLLMManager+TTS` swap from
        // AVSpeechSynthesizer to the selector).
        _ = persona
        return VoiceVoxEngine.shared
    }

    private func makeKokoroEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        _ = persona
        return KokoroEngine.shared
    }

    private func makeSystemTTSEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        _ = persona
        return SystemTTSEngine()
    }
}
