//
//  PersonaSettingsView+KokoroDownload.swift
//  NeuraLink
//
//  Surfaces the Kokoro voice-pack download UX inside PersonaSettings —
//  the button + progress + error states + the async downloader that
//  drives them. Extracted from `PersonaSettingsView.swift` to keep that
//  file under the swiftlint file-length ceiling.
//
//  Trigger flow: tapping "Download voice pack" calls into
//  `RemoteAssetCache.shared.url(for:)` for each of the three big Kokoro
//  assets (`.kokoroModel`, `.kokoroVoices`, `.kokoroCMU`). On success,
//  `kokoroAvailable` flips to true and the selector cache is invalidated
//  for the current persona so the next `speak()` resolves to
//  `KokoroEngine` instead of the `SystemTTSEngine` fallback.
//
//  Created by Dedicatus on 29/05/2026.
//

import SwiftUI

extension PersonaSettingsView {

    @ViewBuilder
    var kokoroDownloadButton: some View {
        Button {
            Task { await downloadKokoroVoices() }
        } label: {
            HStack {
                if isDownloadingKokoro {
                    ProgressView()
                    Text("Downloading voice pack…")
                } else {
                    Image(systemName: "arrow.down.circle")
                    Text("Download voice pack (~382 MB)")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(isDownloadingKokoro)
    }

    @ViewBuilder
    var kokoroFooter: some View {
        if let error = kokoroDownloadError {
            Label("Download failed: \(error)", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if kokoroAvailable {
            Text("Used by the on-device LLM for English speech synthesis.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                "Kokoro voice pack not installed — falls back to the iOS system voice until you download it.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @MainActor
    func downloadKokoroVoices() async {
        isDownloadingKokoro = true
        kokoroDownloadError = nil
        do {
            _ = try await RemoteAssetCache.shared.url(for: .kokoroModel)
            _ = try await RemoteAssetCache.shared.url(for: .kokoroVoices)
            _ = try await RemoteAssetCache.shared.url(for: .kokoroCMU)
            kokoroAvailable = KokoroModelAccess.isAvailable
            // Drop the cached SystemTTSEngine for this persona so the
            // next speak() resolves to KokoroEngine now that the assets
            // are on disk.
            TTSEngineSelector.shared.invalidateCache(for: modelID)
        } catch {
            kokoroDownloadError = "\(error)"
        }
        isDownloadingKokoro = false
    }
}
