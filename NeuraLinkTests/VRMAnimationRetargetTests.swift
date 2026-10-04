//
//  VRMAnimationRetargetTests.swift
//  NeuraLinkTests
//
//  End-to-end retarget check per VRMC_vrm_animation-1.0: a clip played on a
//  model must point every limb where the clip's own skeleton points it.
//  Expected directions come from plain forward kinematics on the VRMA's
//  raw node tracks (no retarget code involved); actual ones from posing
//  Sonya (VRM 1.x) and Ekaterina (VRM 0.x, which faces −Z, so x/z mirror).
//
//  Covers both kinds of clip in the bundle: identity-rest exports
//  (VRoid / three-vrm) and non-identity-rest exports (Mixamo via
//  FBX2glTF, UniGLTF) — the latter twisted before the loader normalized
//  through the animation's rest world rotations.
//

import Foundation
import Metal
import Testing
import simd

@testable import NeuraLink

@MainActor
@Suite("VRMA retarget onto VRM 0.x and 1.x", .serialized)
struct VRMAnimationRetargetTests {

    /// Limb segments compared (bone → child bone).
    private static let segments: [(VRMHumanoidBone, VRMHumanoidBone)] = [
        (.leftUpperArm, .leftLowerArm), (.leftLowerArm, .leftHand),
        (.rightUpperArm, .rightLowerArm), (.rightLowerArm, .rightHand),
        (.leftUpperLeg, .leftLowerLeg), (.leftLowerLeg, .leftFoot),
        (.rightUpperLeg, .rightLowerLeg), (.rightLowerLeg, .rightFoot)
    ]

    /// Rest-pose proportions differ slightly between skeletons (a T-pose is
    /// never perfectly identical), so allow a few degrees.
    private static let toleranceDegrees: Float = 12

    @Test(
        "Limbs follow the clip on both VRM versions",
        arguments: ["talking", "speaking", "stretch", "neutral", "peace_sign"])
    func limbsFollowClip(clipName: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let clipURL = try #require(Bundle.main.url(forResource: clipName, withExtension: "vrma"))
        let reference = try ReferenceSkeleton(url: clipURL)

        for character in ["Sonya", "Ekaterina"] {
            let modelURL = try #require(Bundle.main.url(forResource: character, withExtension: "vrm"))
            let model = try await VRMModel.load(from: modelURL, device: device)
            let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)
            let mirror = model.isVRM0

            var worst: Float = 0
            var worstLabel = ""
            for step in 1...4 {
                let time = clip.duration * Float(step) / 5
                pose(model, with: clip, at: time)
                let expected = reference.worldPositions(at: time)
                for (from, to) in Self.segments {
                    guard let a = expected[from], let b = expected[to],
                          let actualA = worldPosition(model, from), let actualB = worldPosition(model, to)
                    else { continue }
                    var want = simd_normalize(b - a)
                    if mirror { want = SIMD3(-want.x, want.y, -want.z) }
                    let got = simd_normalize(actualB - actualA)
                    let error = acos(min(1, max(-1, simd_dot(want, got)))) * 180 / .pi
                    if error > worst {
                        worst = error
                        worstLabel = "\(from.rawValue)→\(to.rawValue) @\(String(format: "%.2f", time))s"
                    }
                }
            }
            #expect(worst < Self.toleranceDegrees,
                    "\(clipName) on \(character): worst \(String(format: "%.1f", worst))° at \(worstLabel)")
        }
    }

    // MARK: - Model side

    private func pose(_ model: VRMModel, with clip: AnimationClip, at time: Float) {
        model.withLock {
            for track in clip.jointTracks {
                guard let index = model.humanoid?.getBoneNode(track.bone), index < model.nodes.count else { continue }
                let node = model.nodes[index]
                let (rotation, translation, _) = track.sample(at: time)
                if let rotation { node.rotation = rotation }
                if let translation, track.bone != .hips { node.translation = translation }
                node.updateLocalMatrix()
            }
            model.updateNodeTransforms()
        }
    }

    private func worldPosition(_ model: VRMModel, _ bone: VRMHumanoidBone) -> SIMD3<Float>? {
        guard let index = model.humanoid?.getBoneNode(bone), index < model.nodes.count else { return nil }
        return model.nodes[index].worldPosition
    }
}

/// The VRMA's own skeleton, posed by forward kinematics from its raw tracks.
private struct ReferenceSkeleton {
    let document: GLTFDocument
    let parentOf: [Int: Int]
    let boneNodes: [VRMHumanoidBone: Int]
    let rotationTracks: [Int: KeyTrack]
    let translationTracks: [Int: KeyTrack]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let buffer = BufferLoader(document: document, binaryData: binary, baseURL: url.deletingLastPathComponent())
        self.document = document

        var parents: [Int: Int] = [:]
        for (index, node) in (document.nodes ?? []).enumerated() {
            for child in node.children ?? [] { parents[child] = index }
        }
        parentOf = parents

        var rotations: [Int: KeyTrack] = [:]
        var translations: [Int: KeyTrack] = [:]
        if let animation = document.animations?.first {
            for channel in animation.channels {
                guard let node = channel.target.node else { continue }
                let sampler = animation.samplers[channel.sampler]
                let path = channel.target.path
                guard path == "rotation" || path == "translation" else { continue }
                let track = KeyTrack(
                    times: try buffer.loadAccessorAsFloat(sampler.input),
                    values: try buffer.loadAccessorAsFloat(sampler.output),
                    path: path, interpolation: Interpolation(sampler.interpolation),
                    componentCount: path == "rotation" ? 4 : 3)
                if path == "rotation" { rotations[node] = track } else { translations[node] = track }
            }
        }
        rotationTracks = rotations
        translationTracks = translations
        boneNodes = Self.humanBones(in: data)
    }

    func worldPositions(at time: Float) -> [VRMHumanoidBone: SIMD3<Float>] {
        var cache: [Int: (rotation: simd_quatf, position: SIMD3<Float>)] = [:]
        func world(_ index: Int) -> (rotation: simd_quatf, position: SIMD3<Float>) {
            if let hit = cache[index] { return hit }
            let rest = RestTransform(node: document.nodes![index])
            let rotation = rotationTracks[index].map { sampleQuaternion($0, at: time) } ?? rest.rotation
            let translation = translationTracks[index].map { sampleVector3($0, at: time) } ?? rest.translation
            let result: (rotation: simd_quatf, position: SIMD3<Float>)
            if let parent = parentOf[index] {
                let parentWorld = world(parent)
                result = (simd_normalize(parentWorld.rotation * rotation),
                          parentWorld.position + parentWorld.rotation.act(translation))
            } else {
                result = (simd_normalize(rotation), translation)
            }
            cache[index] = result
            return result
        }
        return boneNodes.mapValues { world($0).position }
    }

    /// `extensions.VRMC_vrm_animation.humanoid.humanBones` from the GLB JSON chunk.
    private static func humanBones(in glb: Data) -> [VRMHumanoidBone: Int] {
        guard glb.count > 20 else { return [:] }
        let length = glb.subdata(in: 12..<16).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
        guard let json = try? JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + length))) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let animation = extensions["VRMC_vrm_animation"] as? [String: Any],
              let humanoid = animation["humanoid"] as? [String: Any],
              let bones = humanoid["humanBones"] as? [String: [String: Any]]
        else { return [:] }
        var map: [VRMHumanoidBone: Int] = [:]
        for (name, entry) in bones {
            if let bone = VRMHumanoidBone(rawValue: name), let node = entry["node"] as? Int { map[bone] = node }
        }
        return map
    }
}
