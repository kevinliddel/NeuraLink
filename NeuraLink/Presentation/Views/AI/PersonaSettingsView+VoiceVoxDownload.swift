//
//  PersonaSettingsView+VoiceVoxDownload.swift
//  NeuraLink
//
//  Mirrors `+KokoroDownload` for the VOICEVOX path. Surfaces the
//  Japanese voice-pack download UX inside PersonaSettings — the button
//  + progress + error states + the async downloader that drives them.
//  Extracted from `PersonaSettingsView.swift` to keep that file under
//  the swiftlint file-length ceiling.
//
//  Trigger flow: tap "Download Japanese voice pack" → fan-out fetches
//  all Open JTalk dict files in parallel, then the currently-selected
//  speaker's `.vvm`. Total varies by speaker (~150 MB dict + ~57 MB
//  vvm = ~210 MB). On success, `voicevoxAvailable` flips to true and
//  the selector cache is invalidated for the current persona so the
//  next `speak()` resolves through the loaded VOICEVOX engine.
//
//  Created by Dedicatus on 29/05/2026.
//

import SwiftUI

extension PersonaSettingsView {

    @ViewBuilder
    var voicevoxDownloadButton: some View {
        Button {
            Task { await downloadVoiceVoxPack() }
        } label: {
            HStack {
                if isDownloadingVoiceVox {
                    ProgressView()
                    Text("Downloading Japanese voice pack…")
                } else {
                    Image(systemName: "arrow.down.circle")
                    Text("Download Japanese voice pack (~210 MB)")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(isDownloadingVoiceVox)
    }

    @ViewBuilder
    var voicevoxFooter: some View {
        if let error = voicevoxDownloadError {
            Label("Download failed: \(error)", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if voicevoxAvailable {
            Text("Used by the Japanese local LLM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                "VOICEVOX dictionary not installed — Japanese TTS will fall back to the iOS system voice until you download it.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @MainActor
    func downloadVoiceVoxPack() async {
        isDownloadingVoiceVox = true
        voicevoxDownloadError = nil
        do {
            // Dict files: fan out, every file landing in the same
            // <App Support>/hf-assets/tts/voicevox/open_jtalk_dic/.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for filename in RemoteAssetRegistry.jtalkDictFilenames {
                    group.addTask {
                        _ = try await RemoteAssetCache.shared.url(
                            for: .jtalkDictFile(filename))
                    }
                }
                try await group.waitForAll()
            }
            // Speaker pack for the currently-selected speaker. The
            // engine will lazy-download any other speaker the user
            // switches to via the same RemoteAssetCache path.
            let mapping = VoiceVoxSpeaker.map(voicevoxSpeakerID)
            _ = try await RemoteAssetCache.shared.url(
                for: .voicevoxSpeaker(mapping.filenameID))

            voicevoxAvailable = VoiceVoxModelAccess.isDictionaryAvailable
            TTSEngineSelector.shared.invalidateCache(for: modelID)
        } catch {
            voicevoxDownloadError = "\(error)"
        }
        isDownloadingVoiceVox = false
    }
}
