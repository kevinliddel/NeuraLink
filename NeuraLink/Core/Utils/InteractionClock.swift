//
//  InteractionClock.swift
//  NeuraLink
//
//  Single authoritative clock for "when did the user last interact" —
//  Living Companion Phase 0 (docs/LIVING_COMPANION_PLAN.md §0.2).
//
//  Two signals with different lifetimes:
//    • lastUserSpeechAt — in-memory, per-launch; feeds in-session silence
//      detection (proactive small talk).
//    • lastSeenAt — persisted; written on app backgrounding, feeds the
//      "hours since last seen" absence math. Kept on one clock (device local
//      Date) deliberately — SQLite message timestamps are UTC strings and
//      must not be mixed into this arithmetic.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation

final class InteractionClock: @unchecked Sendable {
    static let shared = InteractionClock()

    private static let lastSeenKey = "com.neuralink.presence.lastSeenAt"

    private let lock = NSLock()
    private var _lastUserSpeechAt: Date?

    private init() {}

    // MARK: - In-session speech (per-launch)

    /// When the user last spoke or typed a real turn, this launch. Nil until
    /// the first turn. Safe to read from any thread.
    var lastUserSpeechAt: Date? {
        lock.withLock { _lastUserSpeechAt }
    }

    /// Called alongside `ProactiveVisionManager.notifyUserSpoke()` from the
    /// two user-turn sites (local + OpenAI).
    func noteUserSpoke() {
        lock.withLock { _lastUserSpeechAt = Date() }
    }

    /// Seconds of user silence this session, or nil before the first turn.
    var secondsSinceUserSpoke: TimeInterval? {
        lastUserSpeechAt.map { Date().timeIntervalSince($0) }
    }

    // MARK: - Cross-launch absence (persisted)

    /// When the app was last backgrounded (≈ when the user was last seen).
    /// Nil on the very first launch.
    var lastSeenAt: Date? {
        let raw = UserDefaults.standard.double(forKey: Self.lastSeenKey)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Stamped by SessionLifecycle on `didEnterBackground`.
    func markLastSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
    }

    /// Hours since the user was last seen, or nil on first launch.
    var hoursSinceLastSeen: Double? {
        lastSeenAt.map { Date().timeIntervalSince($0) / 3600.0 }
    }
}
