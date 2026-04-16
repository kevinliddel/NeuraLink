//
//  VRMKeyframeInterpolation.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import simd

// MARK: - Track Types

enum Interpolation: String {
    case linear = "LINEAR"
    case step = "STEP"
    case cubicSpline = "CUBICSPLINE"

    init(_ raw: String?) {
        self = raw.flatMap { Interpolation(rawValue: $0.uppercased()) } ?? .linear
    }
}

struct KeyTrack {
    let times: [Float]
    let values: [Float]
    let path: String
    let interpolation: Interpolation
    let componentCount: Int
}

private enum TrackSegment { case value, inTangent, outTangent }

// MARK: - Samplers

func sampleQuaternion(_ track: KeyTrack, at time: Float) -> simd_quatf {
    let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    guard track.componentCount == 4, !track.times.isEmpty else { return identity }

    switch track.interpolation {
    case .step:
        return quaternionValue(from: track, keyIndex: keyframeIndex(track.times, time))

    case .linear:
        let (i, frac) = keyframeIndexAndFrac(track.times, time)
        let q0 = quaternionValue(from: track, keyIndex: i)
        guard i + 1 < track.times.count else { return q0 }
        var q1 = quaternionValue(from: track, keyIndex: i + 1)
        if simd_dot(q0.vector, q1.vector) < 0 { q1 = simd_quatf(vector: -q1.vector) }
        return simd_normalize(simd_slerp(q0, q1, frac))

    case .cubicSpline:
        let (i, frac) = keyframeIndexAndFrac(track.times, time)
        guard i + 1 < track.times.count else { return quaternionValue(from: track, keyIndex: i) }
        let dt = max(1e-6, track.times[i + 1] - track.times[i])
        var v1 = quaternionVector(from: track, keyIndex: i + 1)
        var it1 = quaternionInTangent(from: track, keyIndex: i + 1)
        let v0 = quaternionVector(from: track, keyIndex: i)
        let ot0 = quaternionOutTangent(from: track, keyIndex: i)
        if simd_dot(v0, v1) < 0 {
            v1 = -v1
            it1 = -it1
        }
        let h = hermite(v0, ot0 * dt, v1, it1 * dt, frac)
        return simd_normalize(simd_quatf(ix: h[0], iy: h[1], iz: h[2], r: h[3]))
    }
}

func sampleVector3(_ track: KeyTrack, at time: Float) -> SIMD3<Float> {
    guard track.componentCount == 3, !track.times.isEmpty else { return .zero }

    switch track.interpolation {
    case .step:
        return vectorValue(from: track, keyIndex: keyframeIndex(track.times, time))

    case .linear:
        let (i, frac) = keyframeIndexAndFrac(track.times, time)
        let v0 = vectorValue(from: track, keyIndex: i)
        guard i + 1 < track.times.count else { return v0 }
        let v1 = vectorValue(from: track, keyIndex: i + 1)
        return v0 + (v1 - v0) * frac

    case .cubicSpline:
        let (i, frac) = keyframeIndexAndFrac(track.times, time)
        guard i + 1 < track.times.count else { return vectorValue(from: track, keyIndex: i) }
        let dt = max(1e-6, track.times[i + 1] - track.times[i])
        return hermite(
            vectorValue(from: track, keyIndex: i),
            vectorOutTangent(from: track, keyIndex: i) * dt,
            vectorValue(from: track, keyIndex: i + 1),
            vectorInTangent(from: track, keyIndex: i + 1) * dt,
            frac)
    }
}

// MARK: - Keyframe Lookup

private func keyframeIndex(_ times: [Float], _ time: Float) -> Int {
    guard time > (times.first ?? 0) else { return 0 }
    guard time < (times.last ?? 0) else { return max(0, times.count - 1) }
    for i in (0..<(times.count - 1)).reversed() where time >= times[i] { return i }
    return 0
}

private func keyframeIndexAndFrac(_ times: [Float], _ time: Float) -> (Int, Float) {
    guard !times.isEmpty else { return (0, 0) }
    guard time > times.first! else { return (0, 0) }
    guard time < times.last! else { return (max(0, times.count - 2), 1) }
    for i in 0..<(times.count - 1) {
        if time >= times[i] && time <= times[i + 1] {
            return (i, (time - times[i]) / max(1e-6, times[i + 1] - times[i]))
        }
    }
    return (0, 0)
}

// MARK: - Value Extraction

private func valueRange(
    for track: KeyTrack, keyIndex: Int, componentCount: Int, segment: TrackSegment
) -> Range<Int>? {
    let stride = componentCount * (track.interpolation == .cubicSpline ? 3 : 1)
    let base = keyIndex * stride
    switch track.interpolation {
    case .cubicSpline:
        switch segment {
        case .inTangent: return base..<(base + componentCount)
        case .value: return (base + componentCount)..<(base + 2 * componentCount)
        case .outTangent: return (base + 2 * componentCount)..<(base + 3 * componentCount)
        }
    case .linear, .step:
        guard segment == .value else { return nil }
        return base..<(base + componentCount)
    }
}

private func quaternionVector(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .value),
        r.upperBound <= track.values.count
    else { return SIMD4<Float>(0, 0, 0, 1) }
    return SIMD4<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2], track.values[r.lowerBound + 3])
}

private func quaternionValue(from track: KeyTrack, keyIndex: Int) -> simd_quatf {
    let v = quaternionVector(from: track, keyIndex: keyIndex)
    return simd_normalize(simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3]))
}

private func quaternionInTangent(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard
        let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .inTangent),
        r.upperBound <= track.values.count
    else { return .zero }
    return SIMD4<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2], track.values[r.lowerBound + 3])
}

private func quaternionOutTangent(from track: KeyTrack, keyIndex: Int) -> SIMD4<Float> {
    guard
        let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 4, segment: .outTangent),
        r.upperBound <= track.values.count
    else { return .zero }
    return SIMD4<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2], track.values[r.lowerBound + 3])
}

private func vectorValue(from track: KeyTrack, keyIndex: Int) -> SIMD3<Float> {
    guard let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 3, segment: .value),
        r.upperBound <= track.values.count
    else { return .zero }
    return SIMD3<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2])
}

private func vectorInTangent(from track: KeyTrack, keyIndex: Int) -> SIMD3<Float> {
    guard
        let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 3, segment: .inTangent),
        r.upperBound <= track.values.count
    else { return .zero }
    return SIMD3<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2])
}

private func vectorOutTangent(from track: KeyTrack, keyIndex: Int) -> SIMD3<Float> {
    guard
        let r = valueRange(for: track, keyIndex: keyIndex, componentCount: 3, segment: .outTangent),
        r.upperBound <= track.values.count
    else { return .zero }
    return SIMD3<Float>(
        track.values[r.lowerBound], track.values[r.lowerBound + 1],
        track.values[r.lowerBound + 2])
}

// MARK: - Hermite Interpolation

private func hermite(
    _ p0: SIMD3<Float>, _ m0: SIMD3<Float>,
    _ p1: SIMD3<Float>, _ m1: SIMD3<Float>, _ t: Float
) -> SIMD3<Float> {
    let t2 = t * t
    let t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
        + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
}

private func hermite(
    _ p0: SIMD4<Float>, _ m0: SIMD4<Float>,
    _ p1: SIMD4<Float>, _ m1: SIMD4<Float>, _ t: Float
) -> SIMD4<Float> {
    let t2 = t * t
    let t3 = t2 * t
    return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0
        + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
}
