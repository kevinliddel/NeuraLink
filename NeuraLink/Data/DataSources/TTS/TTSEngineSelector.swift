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
//    2. .japaneseLlama1b active                           -> VoiceVoxEngine
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
        for engine in cachedEngines.values {
            engine.stop()
            engine.shutdown()
        }
        cachedEngines.removeAll()
    }

    func invalidateCache(for persona: PersonaIdentifier) {
        if let engine = cachedEngines.removeValue(forKey: persona) {
            engine.stop()
            engine.shutdown()
        }
    }

    private func resolveEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        let config = LocalModelDownloadManager.shared.selectedConfig

        if hasTrainedClone(for: persona), config == .qwen7b {
            return makeF5TTSEngine(for: persona)
        }

        if config == .japaneseLlama1b {
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
        false
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
        nil
    }

    private func makeSystemTTSEngine(for persona: PersonaIdentifier) -> (any TTSEngineProtocol)? {
        _ = persona
        return SystemTTSEngine()
    }
}
