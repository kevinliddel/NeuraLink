//
//  RealtimeLipSyncRenderer.swift
//  NeuraLink
//
//  The mouth cue on the OpenAI path: every buffer WebRTC plays from the
//  remote audio track, handed over as it goes to the speaker. LiveKit's
//  WebRTC build adds this renderer hook to audio tracks; the upstream build
//  the app used until 2026-11-03 had none, and the mouth was driven from a
//  loudness statistic instead. The buffers arrive on WebRTC's playout
//  thread, 10 ms at a time, as 16-bit PCM; the renderer converts the first
//  channel into a buffer of its own, runs the analyzer (RMS, three bands,
//  a vowel) and publishes to LipSyncFeed, which the render tick reads once
//  a frame. See docs/LipSync.md.
//
//  Created by Dedicatus on 03/11/2026.
//

import AVFoundation
import Accelerate
import Foundation
import LiveKitWebRTC

nonisolated final class RealtimeLipSyncRenderer: NSObject, LKRTCAudioRenderer {
    /// Frames the conversion buffer holds: a playout buffer is 10 ms, 480
    /// frames at 48 kHz, and nothing longer is expected.
    static let capacity = 4_096

    private let analyzer = LipSyncAudioAnalyzer()
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    /// The track wrapper, held strongly: the renderer list lives in the
    /// wrapper, not in the native track, and the delegate hands out a fresh
    /// wrapper per call that nobody else keeps. Held weakly it was released
    /// at once and its deallocation took the sink off the track (2026-11-03,
    /// "renderer attached" twice and never a buffer).
    private var track: LKRTCAudioTrack?
    private let lock = NSLock()
    /// Playout buffers seen since the attach; the first one is logged with
    /// its format, the proof on a phone that the hook delivers.
    private var buffers = 0

    deinit {
        samples.deallocate()
    }

    /// Hears `track` until `detach()`. Attaching to the track already heard
    /// (another wrapper of the same native track) is a no-op.
    func attach(to track: LKRTCAudioTrack) {
        lock.lock()
        defer { lock.unlock() }
        guard track.trackId != self.track?.trackId else { return }
        release()
        track.add(self)
        self.track = track
        buffers = 0
        nlLog("[LipSync] renderer attached to remote track \(track.trackId)", level: .info)
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        release()
    }

    private func release() {
        if let track {
            track.remove(self)
            nlLog("[LipSync] renderer detached after \(buffers) playout buffers", level: .info)
        }
        track = nil
        LipSyncFeed.shared.reset()
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        ingest(pcmBuffer)
    }

    /// The first channel of `buffer`, as floats, analysed and published.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let frames = min(Int(buffer.frameLength), Self.capacity)
        guard frames > 0 else { return }
        let format = buffer.format
        let stride = format.isInterleaved ? vDSP_Stride(format.channelCount) : 1
        if let int16 = buffer.int16ChannelData {
            var scale: Float = 1 / 32_768
            vDSP_vflt16(int16[0], stride, samples, 1, vDSP_Length(frames))
            vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(frames))
        } else if let float = buffer.floatChannelData {
            var zero: Float = 0
            vDSP_vsadd(float[0], stride, &zero, samples, 1, vDSP_Length(frames))
        } else {
            return
        }
        let cue = analyzer.analyze(UnsafeBufferPointer(start: samples, count: frames), sampleRate: format.sampleRate)
        LipSyncFeed.shared.publish(cue.sample)
        buffers += 1
        if buffers == 1 {
            nlLog(
                "[LipSync] first playout buffer: \(frames) frames, \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, "
                    + "\(buffer.int16ChannelData != nil ? "int16" : "float32")\(format.isInterleaved ? " interleaved" : ""), "
                    + "rms \(String(format: "%.3f", cue.rms))",
                level: .info)
        }
    }
}
