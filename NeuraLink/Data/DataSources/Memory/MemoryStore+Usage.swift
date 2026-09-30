//
//  MemoryStore+Usage.swift
//  NeuraLink
//
//  `api_usage` — one row per metered OpenAI call (docs/API_USAGE.md).
//  `created_at` is Unix seconds so range filters are plain comparisons and
//  bucketing can use SQLite's 'localtime' modifier.
//
//  Created by Dedicatus on 30/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// How long usage rows are kept.
    static let usageRetention: TimeInterval = 400 * 86_400

    func insertUsage(_ record: UsageRecord, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        INSERT INTO api_usage (created_at, source, model, purpose, input_tokens, output_tokens,
            cached_input_tokens, audio_input_tokens, audio_output_tokens, audio_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, (record.source.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (record.model as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (record.purpose as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 5, Int64(record.inputTokens))
            sqlite3_bind_int64(statement, 6, Int64(record.outputTokens))
            sqlite3_bind_int64(statement, 7, Int64(record.cachedInputTokens))
            sqlite3_bind_int64(statement, 8, Int64(record.audioInputTokens))
            sqlite3_bind_int64(statement, 9, Int64(record.audioOutputTokens))
            sqlite3_bind_double(statement, 10, record.audioSeconds)
            if sqlite3_step(statement) != SQLITE_DONE {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                nlLog("[MemoryStore] Error inserting usage: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
    }

    /// Calls in `[from, to)` summed per local hour (`hourly`) or local day,
    /// per source / model / purpose. Oldest bucket first.
    func usageBuckets(from: Date, to: Date, hourly: Bool) -> [UsageBucket] {
        lock.lock()
        defer { lock.unlock() }
        let format = hourly ? "%Y-%m-%d %H:00" : "%Y-%m-%d 00:00"
        let query = """
        SELECT strftime('\(format)', created_at, 'unixepoch', 'localtime') AS bucket,
               source, model, purpose, COUNT(*),
               SUM(input_tokens), SUM(output_tokens), SUM(cached_input_tokens),
               SUM(audio_input_tokens), SUM(audio_output_tokens), SUM(audio_seconds)
        FROM api_usage
        WHERE created_at >= ? AND created_at < ?
        GROUP BY bucket, source, model, purpose
        ORDER BY bucket;
        """
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd HH:mm"

        var statement: OpaquePointer?
        var buckets: [UsageBucket] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawBucket = sqlite3_column_text(statement, 0),
                    let start = parser.date(from: String(cString: rawBucket)),
                    let rawSource = sqlite3_column_text(statement, 1),
                    let source = UsageSource(rawValue: String(cString: rawSource))
                else { continue }
                var totals = UsageRecord(
                    source: source,
                    model: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                    purpose: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "")
                totals.inputTokens = Int(sqlite3_column_int64(statement, 5))
                totals.outputTokens = Int(sqlite3_column_int64(statement, 6))
                totals.cachedInputTokens = Int(sqlite3_column_int64(statement, 7))
                totals.audioInputTokens = Int(sqlite3_column_int64(statement, 8))
                totals.audioOutputTokens = Int(sqlite3_column_int64(statement, 9))
                totals.audioSeconds = sqlite3_column_double(statement, 10)
                buckets.append(UsageBucket(
                    start: start, requests: Int(sqlite3_column_int(statement, 4)), totals: totals))
            }
        }
        sqlite3_finalize(statement)
        return buckets
    }

    func deleteAllUsage() {
        execUsage("DELETE FROM api_usage;")
    }

    func deleteUsage(from: Date, to: Date) {
        execUsage(
            "DELETE FROM api_usage WHERE created_at >= \(from.timeIntervalSince1970) AND created_at < \(to.timeIntervalSince1970);")
    }

    /// Drops rows older than `usageRetention`.
    func pruneUsage(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.usageRetention).timeIntervalSince1970
        execUsage("DELETE FROM api_usage WHERE created_at < \(cutoff);")
    }

    private func execUsage(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }
}

/// Single entry point for metering: persists one call and pings the
/// dashboard. Empty payloads (a response with no usage) are dropped.
enum UsageRecorder {
    static let didChange = Notification.Name("NLAPIUsageDidChange")

    private static var pruned = false

    static func record(_ record: UsageRecord) {
        guard !record.isEmpty else { return }
        let store = MemoryStore.shared
        if !pruned {
            pruned = true
            store.pruneUsage()
        }
        store.insertUsage(record)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
