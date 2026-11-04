//
//  ModelDownloadPinTests.swift
//  NeuraLinkTests
//
//  Every model fetched from a Hugging Face repo we don't own must name a
//  commit (not `main`) and carry a size + SHA-256 pin, so an upstream
//  re-upload can neither reach llama.cpp's loader nor break the download.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Model download pins")
struct ModelDownloadPinTests {

    private static let commitPattern = /^[0-9a-f]{40}$/
    private static let sha256Pattern = /^[0-9a-f]{64}$/

    private func expectWellFormed(_ pin: RemoteAssetRegistry.AssetIntegrity) {
        #expect(pin.size > 0)
        #expect(pin.sha256.wholeMatch(of: Self.sha256Pattern) != nil)
    }

    @Test("Llama 3.2 GGUF is pinned to a commit and a hash")
    func llamaPinned() throws {
        #expect(GGUFModelAccess.revision.wholeMatch(of: Self.commitPattern) != nil)
        expectWellFormed(GGUFModelAccess.integrity)
        let url = try #require(GGUFDirectDownloader.remoteURL(
            repoID: GGUFModelAccess.repoID, revision: GGUFModelAccess.revision,
            filename: GGUFModelAccess.filename))
        #expect(url.absoluteString.contains("/resolve/\(GGUFModelAccess.revision)/"))
        #expect(url.scheme == "https")
    }

    @Test("LLM-jp-3 GGUF is pinned to a commit and a hash")
    func llmJpPinned() throws {
        #expect(GGUFLLMjp3ModelAccess.revision.wholeMatch(of: Self.commitPattern) != nil)
        expectWellFormed(GGUFLLMjp3ModelAccess.integrity)
        let url = try #require(GGUFDirectDownloader.remoteURL(
            repoID: GGUFLLMjp3ModelAccess.repoID, revision: GGUFLLMjp3ModelAccess.revision,
            filename: GGUFLLMjp3ModelAccess.filename))
        #expect(url.absoluteString.contains("/resolve/\(GGUFLLMjp3ModelAccess.revision)/"))
    }

    @Test("Registry assets from third-party repos name a commit")
    func thirdPartyRegistryAssetsPinned() throws {
        let url = try #require(RemoteAssetRegistry.embeddingModel.remoteURL)
        #expect(!url.absoluteString.contains("/resolve/main/"))
        expectWellFormed(try #require(RemoteAssetRegistry.embeddingModel.integrity))
    }
}
