//
//  RealtimeLipSyncPoller.swift
//  NeuraLink
//
//  The mouth cue on the OpenAI path. The shipped WebRTC build offers no way
//  at the played samples (no track renderer; only a replacement audio
//  device would), so the cue comes from the connection's statistics: the
//  inbound audio's total energy and total sample duration, read every 50 ms
//  off the main thread and differenced, give the mean power of what was
//  just played out, after the jitter buffer. The `audioLevel` statistic
//  polled before was a peak held over 100 ms and refreshed at that rate,
//  read on the main run loop between frames: the mouth trailed short
//  syllables and held through gaps. A power figure names no shape, so the
//  vowel is left to the controller's cycle.
//  libwebrtc hands back the same report for 50 ms after it collects one
//  (RTCStatsCollector's cache lifetime), so the poll runs every 25 ms and a
//  report with the timestamp of the last one is dropped: otherwise every
//  second poll would read as nothing played and the mouth would flicker
//  shut mid-word. See docs/LipSync.md.
//
//  Created by Dedicatus on 02/11/2026.
//

import Foundation
import WebRTC

/// The level a statistics report yields, with the state the next one
/// needs. Pure, so the arithmetic is tested without a connection.
nonisolated struct LipSyncStatisticsEnvelope: Sendable {
    private var reportTimestamp: CFTimeInterval?
    private var energy: Double?
    private var duration: Double?
    private var normalizer = LipSyncLevelNormalizer()
    private var lastTime: TimeInterval?

    /// nil when the report was already read (the runtime hands back the
    /// same report for 50 ms); otherwise the level of what was played out
    /// since the previous fresh report. Totals that did not advance mean
    /// nothing was played; a build without the totals falls back to the
    /// peak statistic.
    mutating func level(
        reportTimestamp: CFTimeInterval, energy newEnergy: Double?, duration newDuration: Double?, peakLevel: Float?, now: TimeInterval
    ) -> Float? {
        guard reportTimestamp != self.reportTimestamp else { return nil }
        self.reportTimestamp = reportTimestamp
        let elapsed = lastTime.map { now - $0 } ?? 0
        lastTime = now
        var level: Float = 0
        if let newEnergy, let newDuration {
            if let energy, let duration, newDuration > duration {
                let rms = Float(sqrt(max(0, newEnergy - energy) / (newDuration - duration)))
                level = normalizer.level(rms: rms, elapsed: elapsed)
            }
        } else {
            level = peakLevel ?? 0
        }
        energy = newEnergy
        duration = newDuration
        return level
    }
}

nonisolated final class RealtimeLipSyncPoller: @unchecked Sendable {
    /// Half the runtime's report cache lifetime, so a fresh report is read
    /// as soon as it exists.
    static let interval: TimeInterval = 0.025

    /// Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "com.neuralink.lipsync.realtime", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private weak var connection: RTCPeerConnection?
    private var envelope = LipSyncStatisticsEnvelope()

    func start(_ connection: RTCPeerConnection) {
        queue.async { [self] in
            cancelTimer()
            self.connection = connection
            envelope = LipSyncStatisticsEnvelope()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            cancelTimer()
            connection = nil
            LipSyncFeed.shared.reset()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let connection else { return }
        connection.statistics { [weak self] report in
            guard let self else { return }
            let audio = report.statistics.values.first { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "audio" }
            let energy = (audio?.values["totalAudioEnergy"] as? NSNumber)?.doubleValue
            let duration = (audio?.values["totalSamplesDuration"] as? NSNumber)?.doubleValue
            let peak = (audio?.values["audioLevel"] as? NSNumber)?.floatValue
            let stamp = report.timestamp_us
            queue.async { self.publish(reportTimestamp: stamp, energy: energy, duration: duration, peakLevel: peak) }
        }
    }

    private func publish(reportTimestamp: CFTimeInterval, energy: Double?, duration: Double?, peakLevel: Float?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let level = envelope.level(reportTimestamp: reportTimestamp, energy: energy, duration: duration, peakLevel: peakLevel, now: now)
        else { return }
        LipSyncFeed.shared.publish(LipSyncSample(level: level, vowel: nil, time: now))
    }
}
