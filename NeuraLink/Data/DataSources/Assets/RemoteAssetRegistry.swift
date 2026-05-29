//
// RemoteAssetRegistry.swift
// NeuraLink
//
// Catalogues every remote on-demand asset covered by §4.2 (scenes) and
// §4.5 (TTS data) of docs/app_size_reduction_plan.md. Each case carries
// the in-repo path of the shared `Dedicatus/NeuraLink` HuggingFace
// dataset so `RemoteAssetCache` can fetch directly over HTTPS.
//
// The in-repo folder layout (`scenes/`, `tts/kokoro/`, future
// `tts/voicevox/`) is what keeps categories isolated even though they
// share a single dataset repo and a single download path.
//
// `Bundle.main` lookup is the cache's first fallback, so adding a case
// here without removing the bundled file is a no-op until the upload +
// strip steps land — that's what makes this safe to ship incrementally.
//
// Renamed from `SceneAssetRegistry` on 29/05/2026 when the first TTS
// cases joined the enum.
//

import Foundation

enum RemoteAssetRegistry: Hashable, Sendable {
    // Scenes (§4.2)
    case city
    case campus

    // Kokoro TTS data (§4.5)
    case kokoroModel
    case kokoroVoices
    case kokoroCMU

    /// On-disk filename — the basename only. Used for `Bundle.main`
    /// lookup and as the local cache filename. Folder prefix comes
    /// from `pathInRepo`.
    var filename: String {
        switch self {
        case .city:         return "city.glb"
        case .campus:       return "campus.glb"
        case .kokoroModel:  return "kokoro.onnx"
        case .kokoroVoices: return "voices.bin"
        case .kokoroCMU:    return "cmu.txt"
        }
    }

    /// Path inside the shared `Dedicatus/NeuraLink` dataset repo.
    /// Passed to the HF resolve URL — `huggingface.co/datasets/<repo>/
    /// resolve/main/<pathInRepo>` — and used as the relative cache path
    /// under `<App Support>/hf-assets/`.
    var pathInRepo: String {
        switch self {
        case .city, .campus:
            return "scenes/\(filename)"
        case .kokoroModel, .kokoroVoices, .kokoroCMU:
            return "tts/kokoro/\(filename)"
        }
    }

    /// Single shared dataset for every on-demand asset. Keeping one
    /// repo simplifies hosting and licence bookkeeping; the per-asset
    /// folder structure above is what isolates categories.
    static let repoID: String = "Dedicatus/NeuraLink"

    /// True when this asset is resolvable from local disk (bundle or
    /// downloads cache) without a network round-trip. Sync for use in
    /// non-async contexts like `TTSEngineSelector` resolution.
    var isCachedLocally: Bool {
        let resource = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        if Bundle.main.url(forResource: resource, withExtension: ext) != nil {
            return true
        }
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else { return false }
        let cached = support
            .appendingPathComponent("hf-assets")
            .appendingPathComponent(pathInRepo)
        return FileManager.default.fileExists(atPath: cached.path)
    }
}
