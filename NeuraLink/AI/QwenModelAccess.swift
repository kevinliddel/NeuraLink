//
//  QwenModelAccess.swift
//  NeuraLink
//
//  Static namespace for resolving on-disk paths for the
//  mlboydaisuke/qwen3-vl-2b-stateful-coreml Hub repository.
//
//  Repo layout:
//    qwen3_vl_2b_stateful_chunks/
//      chunk_0.mlpackage … chunk_3.mlpackage  (4 body chunks)
//      chunk_head.mlpackage
//      embed_weight.bin                        (622 MB token embedding table)
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation

enum QwenModelAccess {
    static let repoID = "mlboydaisuke/qwen3-vl-2b-stateful-coreml"
    static let tokenizerID = "Qwen/Qwen3-VL-2B-Instruct"

    private static let bodyChunkCount = 4
    private static let chunkSubdir = "qwen3_vl_2b_stateful_chunks"
    private static let snapshotKey = "LocalModel_QwenSnapshotPath"
    private static let hubSlug = "models--mlboydaisuke--qwen3-vl-2b-stateful-coreml"

    // MARK: - URL resolution

    /// The chunk subdirectory that directly contains chunk_N.mlpackage files, or nil.
    static func chunkDir() -> URL? {
        if let stored = UserDefaults.standard.string(forKey: snapshotKey) {
            let url = URL(fileURLWithPath: stored)
            if isComplete(at: url) { return url }
        }
        return scanHubCache()
    }

    /// The snapshot root (parent of chunkSubdir) — may contain tokenizer files.
    static func snapshotRoot() -> URL? { chunkDir()?.deletingLastPathComponent() }

    static func chunkURL(index: Int) -> URL? {
        chunkDir()?.appendingPathComponent("chunk_\(index).mlpackage")
    }

    static func headChunkURL() -> URL? {
        chunkDir()?.appendingPathComponent("chunk_head.mlpackage")
    }

    static func embedWeightURL() -> URL? {
        chunkDir()?.appendingPathComponent("embed_weight.bin")
    }

    // MARK: - State

    static var isDownloaded: Bool { chunkDir() != nil }

    /// Persists the chunk directory path after a successful Hub download.
    static func setChunkDir(_ url: URL) {
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

    private static var requiredNames: [String] {
        (0..<bodyChunkCount).map { "chunk_\($0).mlpackage" }
            + ["chunk_head.mlpackage", "embed_weight.bin"]
    }

    static func isComplete(at dir: URL) -> Bool {
        requiredNames.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private static func scanHubCache() -> URL? {
        let snaps = appSupport.appendingPathComponent("hub/\(hubSlug)/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snaps, includingPropertiesForKeys: nil)
        else { return nil }
        for snap in entries.sorted(by: { $0.path > $1.path }) {
            let sub = snap.appendingPathComponent(chunkSubdir)
            if isComplete(at: sub) {
                UserDefaults.standard.set(sub.path, forKey: snapshotKey)
                return sub
            }
        }
        return nil
    }
}
