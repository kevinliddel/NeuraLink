//
// RemoteAssetRegistry.swift
// NeuraLink
//
// Catalogues every remote on-demand asset (scenes + TTS data). Each case carries
// the in-repo path of the shared `Dedicatus/NeuraLink` HuggingFace
// dataset so `RemoteAssetCache` can fetch directly over HTTPS.
//
// The in-repo folder layout (`scenes/`, `tts/voicevox/`, `tts/open_voice/`)
// is what keeps categories isolated even though they share a single
// dataset repo and a single download path.
//
// `Bundle.main` lookup is the cache's first fallback, so adding a case
// here without removing the bundled file is a no-op until the upload +
// strip steps land — that's what makes this safe to ship incrementally.
//
// Renamed from `SceneAssetRegistry` on 29/05/2026 when the first TTS
// cases joined the enum. VoiceVox cases added 29/05/2026.
//
// Created by Dedicatus on 16/05/2026.
//

import Foundation

// `nonisolated`: pure value logic — under the module's default-MainActor
// isolation the synthesized Hashable conformance would otherwise be
// MainActor-isolated, which the `RemoteAssetCache` actor (which keys its
// tables by this enum) can't use in Swift 6 language mode.
nonisolated enum RemoteAssetRegistry: Hashable, Sendable {
    // Scenes — `name` is the GLB basename (resolves to `scenes/<name>.glb`).
    case scene(String)

    // VOICEVOX TTS data — per-speaker .vvm + Open JTalk dict files.
    case voicevoxSpeaker(Int)
    case jtalkDictFile(String)

    // OpenVoice TTS data — MeloTTS + tone-color converter (+ optional prosody
    // BERT). The local TTS for every non-Japanese voice. Hosted under
    // `tts/open_voice/` in the shared dataset.
    case openVoiceMelo
    case openVoiceConverter
    case openVoiceBert

    // Whisper STT data — multilingual ggml-base model (~141 MB). On-demand
    // because it exceeds GitHub's 100 MB file limit, so it can't be committed;
    // hosted under `stt/whisper/` in the shared dataset.
    case whisperModel

    /// On-disk filename — the basename only. Used for `Bundle.main`
    /// lookup and as the local cache filename. Folder prefix comes
    /// from `pathInRepo`.
    var filename: String {
        switch self {
        case .scene(let name): return "\(name).glb"
        case .voicevoxSpeaker(let id): return "\(id).vvm"
        case .jtalkDictFile(let name): return name
        case .openVoiceMelo: return "melo_en.onnx"
        case .openVoiceConverter: return "voice_conversion.onnx"
        case .openVoiceBert: return "bert_en.onnx"
        case .whisperModel: return "ggml-base.bin"
        }
    }

    /// Path inside the shared `Dedicatus/NeuraLink` dataset repo.
    /// Passed to the HF resolve URL — `huggingface.co/datasets/<repo>/
    /// resolve/main/<pathInRepo>` — and used as the relative cache path
    /// under `<App Support>/hf-assets/`.
    var pathInRepo: String {
        switch self {
        case .scene:
            return "scenes/\(filename)"
        case .voicevoxSpeaker:
            return "tts/voicevox/\(filename)"
        case .jtalkDictFile:
            return "tts/voicevox/open_jtalk_dic/\(filename)"
        case .openVoiceMelo, .openVoiceConverter, .openVoiceBert:
            return "tts/open_voice/\(filename)"
        case .whisperModel:
            return "stt/whisper/\(filename)"
        }
    }

    /// Subdirectory hint for `Bundle.main` lookup when the asset is
    /// shipped inside a folder rather than at bundle root. Lets the
    /// cache resolve bundled assets that aren't in `Resources/`'s flat
    /// search path. `nil` means root-level lookup is sufficient.
    var bundleSubdirectory: String? {
        switch self {
        case .scene:
            return "Models/Environments"
        case .jtalkDictFile:
            return "open_jtalk_dic_utf_8-1.11"
        case .voicevoxSpeaker,
            .openVoiceMelo, .openVoiceConverter, .openVoiceBert,
            .whisperModel:
            return nil
        }
    }

    /// Single shared dataset for every on-demand asset. Keeping one
    /// repo simplifies hosting and licence bookkeeping; the per-asset
    /// folder structure above is what isolates categories.
    static let repoID: String = "Dedicatus/NeuraLink"

    // MARK: - Integrity pinning

    /// Expected size + SHA-256 of a downloaded asset, verified by
    /// `RemoteAssetCache` before a download is accepted into the cache.
    struct AssetIntegrity: Sendable, Equatable {
        let size: Int64
        /// Lowercase hex SHA-256 of the file contents.
        let sha256: String
    }

    /// Pinned integrity for this asset, or `nil` when unknown (e.g. a scene
    /// added upstream after this build shipped — those download unverified
    /// with a logged warning rather than failing outright).
    ///
    /// Hashes are pinned **in-app** rather than fetched from a manifest in the
    /// same dataset: an unsigned manifest next to the assets would be tampered
    /// right along with them, while pinning means a swapped upstream file is
    /// rejected. Values come from the dataset's LFS metadata
    /// (`api/datasets/<repo>/tree/main?recursive=true`, `lfs.oid`) — captured
    /// 2026-07-09; re-capture whenever an asset is re-uploaded.
    var integrity: AssetIntegrity? {
        switch self {
        case .scene(let name):
            return Self.sceneIntegrity[name.lowercased()]
        case .voicevoxSpeaker(let id):
            return Self.voicevoxIntegrity[id]
        case .jtalkDictFile(let name):
            return Self.jtalkIntegrity[name]
        case .openVoiceMelo:
            return .init(
                size: 170_504_820,
                sha256: "2edd3caac5ae5b3f4f4bce5f68438b3520055ae73bc3b7c34d27d120f23da9c2")
        case .openVoiceConverter:
            return .init(
                size: 128_059_568,
                sha256: "a9c8271ec5f66872b775f257c8c045dd5deb84073e2a6b838b8b4d1ca72a7abc")
        case .openVoiceBert:
            return .init(
                size: 95_247_276,
                sha256: "89a7afdf42f3ae90f8389526d37d1fa60d6818cc46422d02af73d79feaca34c5")
        case .whisperModel:
            return .init(
                size: 147_951_465,
                sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe")
        }
    }

    /// Keyed by lowercase GLB basename (matches `EnvironmentCatalog` ids).
    private static let sceneIntegrity: [String: AssetIntegrity] = [
        "apartment": .init(
            size: 69_700_696,
            sha256: "ddad8e850799e57c838d083d320dd4d4c8cd7da151bf27c81cd88280f8dace13"),
        "art_gallery": .init(
            size: 23_246_668,
            sha256: "6ca7d5caaae5082447bc8612bd3a9efaf281c767ce45e6eaacc8b747a10513cd"),
        "campus": .init(
            size: 83_003_648,
            sha256: "fcaf2e271ad80e932245eb072ac4adc9f9f757d018451522c6a2f376d1bcf6e1"),
        "city": .init(
            size: 101_226_320,
            sha256: "6434853fbcbe12c7cf5863680b92127109bdc18020af65638ee69fb0a7fe9832"),
        "ruined_city": .init(
            size: 81_496_064,
            sha256: "00c177807cb464e0488a6d53a5437f345285228ed6916575b0dd27cac4777bc8")
    ]

    /// Keyed by `.vvm` filename ID (see `voicevoxSpeakerIDs`).
    private static let voicevoxIntegrity: [Int: AssetIntegrity] = [
        2: .init(
            size: 58_214_778,
            sha256: "4c97ff029895a819cee3ad431a77284d6af7e097ac42faa5af1c87d2bc5a9b5c"),
        3: .init(
            size: 61_730_024,
            sha256: "be05ba9a196bc5acc298daa2c85de1188f0795b46422581437e2b07071963e03"),
        8: .init(
            size: 58_210_984,
            sha256: "bde9cb507f62277a176cc2c7182db686294028d2adff4d3a49c39dd1498f2fed"),
        9: .init(
            size: 57_235_017,
            sha256: "5145551d31ed4fab14d7921aafdd2db5c9e90da40d5b59f9418ee435c400c2fa"),
        14: .init(
            size: 64_664_926,
            sha256: "baab280d80769f1d8fd5aead07137c5ed1b5e61acc5f0e26dff53439e907d085"),
        20: .init(
            size: 59_535_608,
            sha256: "76838e388d3c0bb5bfae7423077132c3a7b1bd9bffd7a2b581b2cc292d1c48d7")
    ]

    /// Keyed by dict filename (see `jtalkDictFilenames`).
    private static let jtalkIntegrity: [String: AssetIntegrity] = [
        "COPYING": .init(
            size: 5_865,
            sha256: "f4eca42ebd930e2c6e57fca58319d989bebcd1510cb7714b149c50f5425135ea"),
        "char.bin": .init(
            size: 262_496,
            sha256: "888ee94c5a8a7a26d24ab3f1b7155441351954fd51ea06b4a2f78bd742492b2f"),
        "left-id.def": .init(
            size: 77_672,
            sha256: "db1adac8a7f9e5854cd82ea044c85115249206c8181b9d88cf92ae2ee5e87b84"),
        "matrix.bin": .init(
            size: 3_792_262,
            sha256: "62fd16b4f64c851d5dc352ef0d5740c5fc83ddc7c203b2b0b1fc5271969a14ce"),
        "pos-id.def": .init(
            size: 1_923,
            sha256: "3460aa742053085af47cdfc889a1e0e6f557e89b406e501ba81c9ccc286de0c7"),
        "rewrite.def": .init(
            size: 7_457,
            sha256: "7f7c8dfbfe24092e8a149a9b6e0a3a7f1c2cf37d6c3dc29d1cccc6c004da9c1c"),
        "right-id.def": .init(
            size: 77_672,
            sha256: "db1adac8a7f9e5854cd82ea044c85115249206c8181b9d88cf92ae2ee5e87b84"),
        "sys.dic": .init(
            size: 103_073_776,
            sha256: "ca57d9029691a70a5dfb99afc2844180256161d7130da65b1a867510e129b9a6"),
        "unk.dic": .init(
            size: 5_690,
            sha256: "ce97851ecda075914fa3ffe7294a1ab34ee4f6d56ba6bf9197d74143b5dffbfe")
    ]

    /// Manifest of every file inside the bundled Open JTalk dictionary
    /// (`open_jtalk_dic_utf_8-1.11/`). VOICEVOX needs the whole set —
    /// missing any one file makes `voicevox_open_jtalk_rc_new` fail.
    /// Order is irrelevant; downloads fan out in parallel.
    static let jtalkDictFilenames: [String] = [
        "COPYING",
        "char.bin",
        "left-id.def",
        "matrix.bin",
        "pos-id.def",
        "rewrite.def",
        "right-id.def",
        "sys.dic",
        "unk.dic"
    ]

    /// All speaker `.vvm` filename IDs shipped today. Source of truth is
    /// the `VoiceVoxSpeaker.allBuiltIn` array but kept duplicated here
    /// to avoid a layering import (registry shouldn't know about the
    /// VoiceVox speaker type).
    static let voicevoxSpeakerIDs: [Int] = [2, 3, 8, 9, 14, 20]

    /// True when this asset is resolvable from local disk (bundle or
    /// downloads cache) without a network round-trip. Sync for use in
    /// non-async contexts like `TTSEngineSelector` resolution.
    var isCachedLocally: Bool {
        let resource = (filename as NSString).deletingPathExtension
        let rawExt = (filename as NSString).pathExtension
        let ext: String? = rawExt.isEmpty ? nil : rawExt
        if Bundle.main.url(forResource: resource, withExtension: ext) != nil {
            return true
        }
        if let subdir = bundleSubdirectory,
            Bundle.main.url(
                forResource: resource,
                withExtension: ext,
                subdirectory: subdir) != nil {
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
        let cached =
            support
            .appendingPathComponent("hf-assets")
            .appendingPathComponent(pathInRepo)
        return FileManager.default.fileExists(atPath: cached.path)
    }
}
