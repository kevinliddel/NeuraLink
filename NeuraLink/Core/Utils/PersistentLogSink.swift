//
// PersistentLogSink.swift
// NeuraLink
//
// Tees `nlLog` writes (DEBUG-only) into a daily rolling file at
// `<Application Support>/logs/YYYY-MM-DD.log` so that `[Bench]`,
// `[KVCache]`, `[AI Event Received]`, and `[AI ERROR EVENT]` lines
// survive device disconnect and app restarts.
//
// Sink failures must never affect runtime behaviour: every I/O path is
// best-effort and silently drops on error.
//
// Privacy note: `nlLogSensitive` writes do NOT route through this sink.
// Only `nlLog` (diagnostic / structured / non-PII) does. Until an in-app
// "Share logs" UI is reviewed for privacy, log retrieval is via Xcode →
// Devices → file-sharing or the simulator's container path.
//
// Created by Dedicatus on 28/05/2026.
//

#if DEBUG
import Foundation

enum PersistentLogSink {
    /// Total bytes across all rotated files. Oldest-first eviction keeps
    /// the directory under this cap. ~10 MB lets us hold several days of
    /// dense benchmarking without unbounded growth.
    private static let maxTotalBytes = 10 * 1024 * 1024

    /// Serial queue so reads/writes/eviction can't interleave. Background
    /// QoS — we never want the sink on the critical path.
    private static let queue = DispatchQueue(
        label: "com.dedicatus.NeuraLink.LogSink",
        qos: .utility)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Append one structured line. Caller has already evaluated the
    /// message autoclosure. Format mirrors what the OSLog stream shows
    /// so a tail of the file reads identically to Console.app.
    static func write(
        level: NLLogLevel,
        body: String,
        category: String,
        function: String,
        line: UInt
    ) {
        let timestamp = timestampFormatter.string(from: Date())
        let formatted = "\(timestamp) [\(level.rawValue)] [\(category)] \(body) [\(function)#\(line)]\n"
        queue.async {
            guard let data = formatted.data(using: .utf8) else { return }
            append(data)
        }
    }

    /// Returns the path the sink is currently writing to. Lets dev UI /
    /// Xcode console code surface the location for retrieval.
    static func currentLogFilePath() -> String? {
        currentLogFileURL()?.path
    }

    // MARK: - File I/O

    private static func append(_ data: Data) {
        guard let url = currentLogFileURL() else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            enforceTotalCap()
        } catch {
            // Best-effort: never propagate sink errors.
        }
    }

    private static func logsDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func currentLogFileURL() -> URL? {
        guard let dir = logsDirectoryURL() else { return nil }
        let filename = dayFormatter.string(from: Date()) + ".log"
        return dir.appendingPathComponent(filename)
    }

    /// Oldest-first eviction until the directory total fits under
    /// `maxTotalBytes`. Never deletes the file we just wrote to.
    private static func enforceTotalCap() {
        guard let dir = logsDirectoryURL() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry {
            let url: URL
            let modified: Date
            let size: Int
        }

        let files: [Entry] = entries.compactMap { url in
            let r = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey
            ])
            guard let date = r?.contentModificationDate,
                  let size = r?.fileSize else { return nil }
            return Entry(url: url, modified: date, size: size)
        }

        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxTotalBytes else { return }

        let active = currentLogFileURL()
        let sorted = files.sorted { $0.modified < $1.modified }
        for entry in sorted {
            if total <= maxTotalBytes { break }
            if entry.url == active { continue }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
#endif
