//
//  LiveMotionClipTests.swift
//  NeuraLinkTests
//
//  The live clip must pose a model exactly as the VRMA path does for the
//  same ARDY frames: the Phase 0 driver wrote ardy_wave_s1.vrma from the
//  raw frames in ardy_wave_s1_frames.json, so playing both on each bundled
//  character (VRM 0.x and 1.x) at frame-aligned moments has to give the
//  same bone rotations and hips height. Plus the buffer's time base: hold
//  past the end, interpolate between frames, survive trimming.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import Metal
import Testing
import simd

@testable import NeuraLink

private final class LiveMotionFixtureMarker {}

private struct LiveMotionFrames: Decodable {
    let fps: Float
    let frames: Int
    let globalRotations: [[Float]]
    let rootPositions: [[Float]]
    enum CodingKeys: String, CodingKey {
        case fps, frames
        case globalRotations = "global_rotations"
        case rootPositions = "root_positions"
    }
}

private struct LiveMotionPosed {
    var rotations: [VRMHumanoidBone: simd_quatf] = [:]
    var hips: SIMD3<Float>?
}

@MainActor
@Suite("Live motion clip", .serialized)
struct LiveMotionClipTests {

    private static let toleranceDegrees: Float = 0.5
    private static let hipsToleranceMetres: Float = 0.002

    @Test(
        "Matches the VRMA path on every bundled character", arguments: ["Oz", "Ekaterina", "Sonya"])
    func matchesVRMAPath(character: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let frames = try Self.loadFrames()
        let vrmaURL = try Self.fixtureURL("ardy_wave_s1", "vrma")
        let modelURL = try #require(Bundle.main.url(forResource: character, withExtension: "vrm"))
        let model = try await VRMModel.load(from: modelURL, device: device)
        let reference = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)

        let session = LiveMotionSession(model: model, framesPerSecond: frames.fps)
        session.append(
            frames: frames.frames, globalRotations: frames.globalRotations.flatMap { $0 },
            rootPositions: frames.rootPositions.flatMap { $0 })
        #expect(session.buffer.frameCount == frames.frames)
        #expect(session.clip.jointTracks.count >= session.retargeter.bones.count)  // plus the finger curl
        #expect(session.clip.duration >= 1_000)

        var worst: Float = 0
        var worstLabel = ""
        var worstHips: Float = 0
        for time: Float in [0.5, 1.5, 2.5, 3.5] {
            let expected = Self.pose(model, with: reference, at: time)
            let actual = Self.pose(model, with: session.clip, at: time)
            for bone in session.retargeter.bones {
                guard let want = expected.rotations[bone], let got = actual.rotations[bone] else {
                    Issue.record("\(character): \(bone.rawValue) missing at \(time)s")
                    continue
                }
                let error = Self.degrees(between: want, got)
                if error > worst {
                    worst = error
                    worstLabel = "\(bone.rawValue) @\(time)s"
                }
            }
            if let want = expected.hips, let got = actual.hips {
                worstHips = max(worstHips, abs(want.y - got.y))
            }
        }
        #expect(
            worst < Self.toleranceDegrees,
            "\(character): worst \(String(format: "%.2f", worst))° at \(worstLabel)")
        #expect(
            worstHips < Self.hipsToleranceMetres,
            "\(character): hips height differs by \(worstHips) m")
    }

    @Test("Buffer holds the last frame, interpolates and keeps its time base when trimmed")
    func bufferTimeBase() {
        let buffer = LiveMotionBuffer(framesPerSecond: 20, retainedFrames: 4)
        #expect(buffer.sample(at: 0) == nil)
        let quarter = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        buffer.append(
            (0..<10).map { frame in
                LiveMotionPose(
                    rotations: [frame % 2 == 0 ? identity : quarter],
                    hipsTranslation: SIMD3<Float>(0, Float(frame), 0))
            })
        #expect(buffer.frameCount == 10)
        #expect(buffer.duration == 0.5)
        // Halfway between frame 0 (identity) and frame 1 (90° about Y): 45°.
        let mid = try? #require(buffer.sample(at: 0.025))
        #expect(abs((mid?.rotations[0].angle ?? 0) * 180 / .pi - 45) < 0.1)
        #expect(abs((mid?.hipsTranslation.y ?? -1) - 0.5) < 1e-5)
        // Past the end: the last frame holds.
        #expect(buffer.sample(at: 5)?.hipsTranslation.y == 9)
        // Trimming drops frames well behind the playhead without moving time.
        buffer.trim(before: 0.45)
        #expect(buffer.frameCount == 10)
        #expect(buffer.sample(at: 0.4)?.hipsTranslation.y == 8)
        #expect(
            buffer.sample(at: 0)?.hipsTranslation.y == 5,
            "frames before the retained window hold the oldest kept frame")
    }

    @Test("The player's clock waits at the last frame for a late window")
    func playerClockWaits() {
        let buffer = LiveMotionBuffer(framesPerSecond: 20, retainedFrames: 200)
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        func frames(_ range: Range<Int>) -> [LiveMotionPose] {
            range.map { LiveMotionPose(rotations: [identity], hipsTranslation: SIMD3<Float>(0, Float($0), 0)) }
        }
        #expect(buffer.samplePlayer(at: 0.3) == nil, "nothing to show before the first window")
        buffer.append(frames(0..<10))  // 0.5 s
        // The clock starts when frames exist: 0.3 s after that first sample is frame 0.
        #expect(buffer.samplePlayer(at: 0.3)?.hipsTranslation.y == 0)
        #expect(abs((buffer.samplePlayer(at: 0.5)?.hipsTranslation.y ?? -1) - 4) < 1e-3)
        #expect(abs(buffer.playhead - 0.2) < 1e-5)
        // The player runs 1 s past the last frame: the body waits there.
        #expect(buffer.samplePlayer(at: 1.5)?.hipsTranslation.y == 9)
        #expect(abs(buffer.playhead - 0.45) < 1e-5)
        #expect(buffer.samplePlayer(at: 1.6)?.hipsTranslation.y == 9, "the same pose while waiting")
        // The late window lands: motion resumes from the frame it stopped on (0.45 s in),
        // not from where the player's clock has got to; 0.1 s later it is on frame 11.
        buffer.append(frames(10..<20))
        #expect(abs((buffer.samplePlayer(at: 1.7)?.hipsTranslation.y ?? -1) - 11) < 1e-3)
        #expect(abs(buffer.playhead - 0.55) < 1e-5)
        #expect(abs((buffer.sample(at: 0.55)?.hipsTranslation.y ?? -1) - 11) < 1e-3, "the plain sampler keeps the buffer's own time")
    }

    // MARK: - Posing

    private static func pose(_ model: VRMModel, with clip: AnimationClip, at time: Float) -> LiveMotionPosed {
        var result = LiveMotionPosed()
        model.withLock {
            for track in clip.jointTracks {
                guard let index = model.humanoid?.getBoneNode(track.bone), index < model.nodes.count
                else { continue }
                let (rotation, translation, _) = track.sample(at: time)
                if let rotation {
                    result.rotations[track.bone] = rotation
                    model.nodes[index].rotation = rotation
                }
                if let translation, track.bone == .hips { result.hips = translation }
                model.nodes[index].updateLocalMatrix()
            }
            model.updateNodeTransforms()
        }
        return result
    }

    private static func degrees(between a: simd_quatf, _ b: simd_quatf) -> Float {
        let dot = min(1, abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector)))
        return 2 * acos(dot) * 180 / .pi
    }

    // MARK: - Fixtures

    private static func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        let bundled = Bundle(for: LiveMotionFixtureMarker.self).url(
            forResource: name, withExtension: ext)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).\(ext)")
        return try #require(
            bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil))
    }

    private static func loadFrames() throws -> LiveMotionFrames {
        try JSONDecoder().decode(
            LiveMotionFrames.self, from: Data(contentsOf: fixtureURL("ardy_wave_s1_frames", "json"))
        )
    }
}
