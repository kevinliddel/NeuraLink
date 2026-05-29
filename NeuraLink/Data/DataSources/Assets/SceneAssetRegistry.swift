//
// SceneAssetRegistry.swift
// NeuraLink
//
// Catalogues the remote on-demand scene assets covered by §4.2 of
// docs/app_size_reduction_plan.md. Each case carries the path inside the
// shared `Dedicatus/NeuraLink` HuggingFace dataset so `RemoteAssetCache`
// can fetch via the same `Hub.Repo` + `HubApi.snapshot(matching:)`
// pattern already used by the GGUF model downloaders.
//
// Leaves the bundled `.glb` files in place
// — the cache prefers bundled, the network is never touched, and
// behaviour is unchanged. Dropping the bundled files turns this into
// the actual −176 MB cut.
//
// Created by Dedicatus on 29/05/2026.
//

import Foundation

enum SceneAssetRegistry: String, CaseIterable, Sendable {
    case city
    case campus

    /// On-disk filename (also the lookup key in `Bundle.main` when the
    /// asset is still bundled).
    var filename: String {
        switch self {
        case .city: return "city.glb"
        case .campus: return "campus.glb"
        }
    }

    /// Path inside the HuggingFace dataset repo — passed to
    /// `HubApi.snapshot(matching:)` so only the one file is fetched.
    var pathInRepo: String {
        "scenes/\(filename)"
    }

    /// Single shared dataset for every category covered by the size
    /// reduction plan (scenes today, TTS assets in §4.5). Keeping one
    /// repo simplifies hosting and licence bookkeeping; the in-repo
    /// folder structure (`scenes/`, `tts/kokoro/`, `tts/voicevox/`) is
    /// what keeps categories isolated.
    static let repoID: String = "Dedicatus/NeuraLink"
}
