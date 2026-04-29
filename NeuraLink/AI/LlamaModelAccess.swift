//
//  LlamaModelAccess.swift
//  NeuraLink
//
//  Static namespace for resolving on-disk paths for the
//  smpanaro/Llama-3.2-1B-Instruct-CoreML Hub repository.
//
//  Repo layout (all .mlmodelc at snapshot root):
//    Llama-3.2-1B-Instruct_chunk1.mlmodelc … chunk6.mlmodelc  (6 body chunks)
//    cache-processor.mlmodelc
//    logit-processor.mlmodelc
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation

enum LlamaModelAccess {
    static let repoID = "smpanaro/Llama-3.2-1B-Instruct-CoreML"
    /// Public Llama-3 tokenizer (compatible with 3.2-1B, no HF gate).
    static let tokenizerID = "NousResearch/Meta-Llama-3-8B-Instruct"

    private static let bodyChunkCount = 6
    private static let snapshotKey = "LocalModel_LlamaSnapshotPath"
    private static let hubSlug = "models--smpanaro--Llama-3.2-1B-Instruct-CoreML"

    // MARK: - URL resolution

    /// The snapshot root directory that contains all .mlmodelc files, or nil.
    static func snapshotDir() -> URL? {
        if let stored = UserDefaults.standard.string(forKey: snapshotKey) {
            let url = URL(fileURLWithPath: stored)
            if isComplete(at: url) { return url }
        }
        return scanHubCache()
    }

    static func chunkURL(index: Int) -> URL? {
        snapshotDir()?.appendingPathComponent(
            "Llama-3.2-1B-Instruct_chunk\(index).mlmodelc")
    }

    static func cacheProcessorURL() -> URL? {
        snapshotDir()?.appendingPathComponent("cache-processor.mlmodelc")
    }

    static func logitProcessorURL() -> URL? {
        snapshotDir()?.appendingPathComponent("logit-processor.mlmodelc")
    }

    // MARK: - State

    static var isDownloaded: Bool { snapshotDir() != nil }

    /// Persists the snapshot path after a successful Hub download.
    static func setSnapshotDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: snapshotKey)
    }

    /// Deletes the Hub cache directory and clears the stored path.
    static func clearCache() {
        let hub = appSupport.appendingPathComponent("hub/\(hubSlug)")
        try? FileManager.default.removeItem(at: hub)
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }

    // MARK: - Internals

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// All file names that must be present for the download to be considered complete.
    private static var requiredNames: [String] {
        (1...bodyChunkCount).map { "Llama-3.2-1B-Instruct_chunk\($0).mlmodelc" }
            + ["cache-processor.mlmodelc", "logit-processor.mlmodelc"]
    }

    static func isComplete(at dir: URL) -> Bool {
        requiredNames.allSatisfy { isValidBundle(at: dir.appendingPathComponent($0)) }
    }

    /// Verifies a `.mlmodelc` bundle is non-empty and contains at least one model file.
    /// A missing or partially-downloaded bundle is an empty directory — MLModel.load
    /// will hang indefinitely on it rather than throwing an error.
    private static func isValidBundle(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let sentinels = ["model.espresso.net", "model.espresso.shape",
                         "coremldata.bin", "metadata.json"]
        return sentinels.contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static func scanHubCache() -> URL? {
        let snaps = appSupport.appendingPathComponent("hub/\(hubSlug)/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snaps, includingPropertiesForKeys: nil)
        else { return nil }
        for snap in entries.sorted(by: { $0.path > $1.path }) {
            if isComplete(at: snap) {
                UserDefaults.standard.set(snap.path, forKey: snapshotKey)
                return snap
            }
        }
        return nil
    }
}
