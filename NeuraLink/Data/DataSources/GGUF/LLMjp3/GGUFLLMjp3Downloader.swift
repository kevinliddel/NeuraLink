//
//  GGUFLLMjp3Downloader.swift
//  NeuraLink
//
//  Downloads the Japanese local model GGUF file from HuggingFace.
//  Model: mmnga/llm-jp-3-1.8b-instruct3-gguf
//  File:  llm-jp-3-1.8b-instruct3-Q3_K_M.gguf (~0.96 GB) — see GGUFLLMjp3ModelAccess
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation
import Hub

enum GGUFLLMjp3Downloader {

    // MARK: - Error

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The Japanese Llama GGUF model file was not found in the downloaded repository."
        }
    }

    // MARK: - API

    static func download(
        api: HubApi,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Direct fetch of the one file, with real byte progress and resume
        // (GGUFDirectDownloader); `api` is kept for the call sites' signature.
        _ = api
        let file = try await GGUFDirectDownloader.download(
            repoID: GGUFLLMjp3ModelAccess.repoID, filename: GGUFLLMjp3ModelAccess.filename, hubSlug: GGUFLLMjp3ModelAccess.hubSlug,
            progress: { progressHandler($0) })
        GGUFLLMjp3ModelAccess.setModelPath(file)
    }

    // MARK: - Private
}
