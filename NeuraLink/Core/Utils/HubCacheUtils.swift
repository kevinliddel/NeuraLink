//
//  HubCacheUtils.swift
//  NeuraLink
//
//  Shared helpers for measuring and clearing on-disk caches produced by
//  HuggingFace `HubApi.snapshot(...)`. All GGUF models cache under
//  `Library/Application Support/hub/models--{user}--{repo}/`; the user-
//  visible "Documents & Data" figure in iOS Settings sums everything
//  under `Library/` plus `Documents/` plus `tmp/`, so reclaim correctness
//  matters.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

enum HubCacheUtils {

    /// Returns the total allocated size in bytes of `url` and every
    /// descendant. Returns 0 if the URL doesn't exist or isn't a directory.
    /// Uses `.totalFileAllocatedSize` so the count reflects on-disk
    /// footprint (including filesystem block padding), matching what iOS
    /// Settings reports under "Documents & Data".
    static func directoryBytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        while let next = enumerator?.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            if let size = values?.totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Removes the on-disk cache at `Library/Application Support/hub/{slug}`,
    /// clears the persisted path stored under `pathKey`, and logs how many
    /// megabytes were freed. Returns the number of bytes that were on disk
    /// before deletion (0 if nothing was there).
    @discardableResult
    static func clear(hubSlug: String, pathKey: String) -> Int64 {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let hub = appSupport.appendingPathComponent("hub/\(hubSlug)")
        let bytes = directoryBytes(at: hub)
        try? FileManager.default.removeItem(at: hub)
        UserDefaults.standard.removeObject(forKey: pathKey)
        if bytes > 0 {
            let mb = Double(bytes) / 1_048_576.0
            nlLog(
                "[HubCache] Cleared \(hubSlug): freed \(String(format: "%.1f", mb)) MB",
                level: .info)
        }
        return bytes
    }
}
