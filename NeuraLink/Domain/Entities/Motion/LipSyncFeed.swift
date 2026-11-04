//
//  LipSyncFeed.swift
//  NeuraLink
//
//  The mouth cue the character's voice is producing right now, whichever
//  path plays it: a level against the recent loudest, and the vowel shape
//  when the audio analysis names one. Audio threads publish it; the render
//  tick reads it once a frame. A cue that is not refreshed goes stale and
//  reads as silence, so a voice that stops mid-word (the connection
//  dropped) closes the mouth instead of holding it open.
//  See docs/LipSync.md.
//
//  Created by Dedicatus on 02/11/2026.
//

import Foundation

/// The five VRM mouth shapes, named as VRM 1.0 names them.
nonisolated enum LipSyncVowel: String, CaseIterable, Sendable {
    case aa, ee, ih, oh, ou
}

nonisolated struct LipSyncSample: Equatable, Sendable {
    /// 0–1: how far the mouth opens, against the recent loudest sound.
    var level: Float
    /// The shape the sound is nearest, or nil when the analysis names none
    /// (silence, or a path that only measures loudness).
    var vowel: LipSyncVowel?
    /// `ProcessInfo.systemUptime` when the audio was measured.
    var time: TimeInterval
}

/// Maps an RMS to a 0–1 level against a peak that halves every 1.5 s, so a
/// quiet voice opens the mouth as far as a loud one and a pause closes it.
nonisolated struct LipSyncLevelNormalizer: Sendable {
    /// Below this RMS nothing counts as sound (about -54 dBFS).
    static let floor: Float = 0.002
    /// The remembered peak halves in this long without a louder sound.
    static let halfLife: TimeInterval = 1.5

    private(set) var peak: Float = 0

    /// `elapsed`: seconds since the previous call.
    mutating func level(rms: Float, elapsed: TimeInterval) -> Float {
        if elapsed > 0 { peak *= Float(pow(0.5, elapsed / Self.halfLife)) }
        peak = max(peak, rms)
        guard rms > Self.floor else { return 0 }
        return min(rms / peak, 1)
    }
}

nonisolated final class LipSyncFeed: @unchecked Sendable {
    static let shared = LipSyncFeed()
    /// A cue older than this reads as silence.
    static let maxAge: TimeInterval = 0.25

    private let lock = NSLock()
    private var latest: LipSyncSample?

    func publish(_ sample: LipSyncSample) {
        lock.withLock { latest = sample }
    }

    /// The latest cue, or nil when there is none or it has gone stale.
    func current(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LipSyncSample? {
        guard let sample = lock.withLock({ latest }), now - sample.time <= Self.maxAge else { return nil }
        return sample
    }

    func reset() {
        lock.withLock { latest = nil }
    }
}
