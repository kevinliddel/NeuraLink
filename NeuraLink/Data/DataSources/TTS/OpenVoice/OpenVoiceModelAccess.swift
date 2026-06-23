//
//  OpenVoiceModelAccess.swift
//  NeuraLink
//
//  Resolves on-disk paths for the OpenVoice TTS assets.
//
//  Big ONNX models (melo_en ~163 MB, voice_conversion ~122 MB, optional
//  bert_en ~91 MB) are on-demand via `RemoteAssetCache` against the public
//  `Dedicatus/NeuraLink` HuggingFace dataset under `tts/open_voice/`.
//  Tiny G2P + speaker-embedding files (g2p_*, bert_vocab, se_*.f32) stay
//  bundled in the app — pointless to make on-demand.
//

import Foundation

enum OpenVoiceModelAccess {

    /// MeloTTS VITS model (~163 MB) — required. Triggers an HF download on
    /// first use; resolves instantly once cached.
    static func meloModel() async throws -> URL {
        try await RemoteAssetCache.shared.url(for: .openVoiceMelo)
    }

    /// Tone-color converter (~122 MB) — required.
    static func converterModel() async throws -> URL {
        try await RemoteAssetCache.shared.url(for: .openVoiceConverter)
    }

    /// Optional prosody BERT (~91 MB). Absent → intonation off, voice still
    /// works. Best-effort: returns nil if it isn't hosted / fails to fetch.
    static func bertModel() async -> URL? {
        try? await RemoteAssetCache.shared.url(for: .openVoiceBert)
    }

    /// True once the two required models are on local disk (no network).
    /// `TTSEngineSelector` consults this to fall back while assets download.
    static var isAvailable: Bool {
        RemoteAssetRegistry.openVoiceMelo.isCachedLocally
            && RemoteAssetRegistry.openVoiceConverter.isCachedLocally
    }

    /// Bundled 256-float base source speaker embedding (required).
    static var sourceSE: URL? {
        Bundle.main.url(forResource: "se_source_en", withExtension: "f32")
    }

    /// Bundled 256-float target voice embedding for `name` (e.g. "se_riko").
    static func targetSE(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "f32")
    }
}
