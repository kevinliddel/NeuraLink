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
//  vowel is left to the controller's cycle. See docs/LipSync.md.
//
//  Created by Dedicatus on 02/11/2026.
//

import Foundation
import WebRTC

nonisolated final class RealtimeLipSyncPoller: @unchecked Sendable {
    static let interval: TimeInterval = 0.05

    /// Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "com.neuralink.lipsync.realtime", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private weak var connection: RTCPeerConnection?
    private var energy: Double?
    private var duration: Double?
    private var normalizer = LipSyncLevelNormalizer()
    private var lastTime: TimeInterval?

    func start(_ connection: RTCPeerConnection) {
        queue.async { [self] in
            cancelTimer()
            self.connection = connection
            energy = nil
            duration = nil
            lastTime = nil
            normalizer = LipSyncLevelNormalizer()
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
            queue.async { self.publish(energy: energy, duration: duration, peakLevel: peak) }
        }
    }

    /// The mean power since the last poll, as a level. Nothing played since
    /// the last poll is silence; a build without the totals falls back to
    /// the peak statistic.
    private func publish(energy newEnergy: Double?, duration newDuration: Double?, peakLevel: Float?) {
        let now = ProcessInfo.processInfo.systemUptime
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
        LipSyncFeed.shared.publish(LipSyncSample(level: level, vowel: nil, time: now))
    }
}
