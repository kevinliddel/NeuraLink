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

import Foundation

enum RemoteAssetRegistry: Hashable, Sendable {
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
        case .scene(let name):         return "\(name).glb"
        case .voicevoxSpeaker(let id): return "\(id).vvm"
        case .jtalkDictFile(let name): return name
        case .openVoiceMelo:           return "melo_en.onnx"
        case .openVoiceConverter:      return "voice_conversion.onnx"
        case .openVoiceBert:           return "bert_en.onnx"
        case .whisperModel:            return "ggml-base.bin"
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
        let cached = support
            .appendingPathComponent("hf-assets")
            .appendingPathComponent(pathInRepo)
        return FileManager.default.fileExists(atPath: cached.path)
    }
}
