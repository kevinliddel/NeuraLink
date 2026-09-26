//
//  CompanionSnapshot.swift
//  NeuraLink (app + NeuraLinkWidgets)
//
//  The only companion data that leaves the protected sandbox: a small JSON
//  snapshot in the App Group container that widgets and Live Activities
//  read (docs/PRESENCE_BEYOND_APP_PLAN.md §P3). Deliberately holds no
//  transcript, facts or observations beyond one hand-picked line.
//  Compiled into both targets, so Foundation only and explicitly
//  nonisolated.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation

nonisolated struct CompanionSnapshot: Codable, Equatable, Sendable {
    static let version = 1

    var version: Int = CompanionSnapshot.version
    /// Character slug / registry name (lowercased) and its display name.
    var character: String
    var displayName: String
    /// Relationship meter as the app shows it.
    var relationshipLabel: String
    var relationshipScore: Double
    /// Greeting prepared for the next conversation (may be empty).
    var opener: String
    /// One short thing the companion remembers, rotated daily (may be empty).
    var memoryLine: String
    /// Last time the user talked with the companion.
    var lastChatAt: Date?
    /// Thumbnail file name inside the group container's `thumbnails/` dir.
    var thumbnailFile: String?
    var updatedAt: Date

    /// Human string for "last chat" ("just now", "3 h ago", "yesterday").
    func lastChatDescription(now: Date = Date()) -> String {
        guard let lastChatAt else { return "No chats yet" }
        let seconds = now.timeIntervalSince(lastChatAt)
        switch seconds {
        case ..<90: return "Just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        case ..<(2 * 86_400): return "Yesterday"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }
}

/// Reads and writes the snapshot in the shared App Group container.
nonisolated enum CompanionSnapshotStore {
    static let appGroupID = "group.com.dedicatus.NeuraLink"
    static let fileName = "companion-snapshot.json"
    static let thumbnailDirectory = "thumbnails"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var snapshotURL: URL? { containerURL?.appendingPathComponent(fileName) }

    static func thumbnailURL(named file: String) -> URL? {
        containerURL?.appendingPathComponent(thumbnailDirectory, isDirectory: true).appendingPathComponent(file)
    }

    static func load() -> CompanionSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompanionSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: CompanionSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Writes a thumbnail PNG; returns the stored file name.
    static func saveThumbnail(_ data: Data, for character: String) -> String? {
        guard let dir = containerURL?.appendingPathComponent(thumbnailDirectory, isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = "\(character.lowercased()).png"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
        return file
    }

    static func clear() {
        guard let container = containerURL else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: container.appendingPathComponent(thumbnailDirectory, isDirectory: true))
    }
}
