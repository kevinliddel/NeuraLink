//
//  CheckingPhoneClipDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: poses both bundled characters with checking_phone.vrma
//  at several moments of the hold and measures what the limb test does not
//  — head tilt, hand direction, every right-hand finger segment and the
//  hand's distance to the head — against the clip's own skeleton, then
//  renders portraits so the grip can be looked at rather than inferred.
//  Set NL_PHONE_CLIP_DIAG_DIR to run.
//

import Foundation
import Metal
import Testing
import UIKit
import simd

@testable import NeuraLink

@MainActor
@Suite("Checking-phone clip diagnostic", .serialized)
struct CheckingPhoneClipDiagnostic {

    private static let clipName = "checking_phone"
    private static let sampleTimes: [Float] = [0, 1.5, 4, 8, 12, 16, 17.5]
    private static let renderTimes: [Float] = [0, 4, 12]

    /// Body segments the limb test already guards plus the spine and head.
    private static let bodySegments: [(String, VRMHumanoidBone, VRMHumanoidBone)] = [
        ("neck→head", .neck, .head), ("spine→chest", .spine, .chest),
        ("chest→upperChest", .chest, .upperChest), ("upperChest→neck", .upperChest, .neck),
        ("R upperArm→lowerArm", .rightUpperArm, .rightLowerArm), ("R lowerArm→hand", .rightLowerArm, .rightHand),
        ("L upperArm→lowerArm", .leftUpperArm, .leftLowerArm), ("L lowerArm→hand", .leftLowerArm, .leftHand)
    ]

    /// Hand orientation and the grip: every right-hand finger segment.
    private static let handSegments: [(String, VRMHumanoidBone, VRMHumanoidBone)] = [
        ("R hand→middle1", .rightHand, .rightMiddleProximal), ("R hand→index1", .rightHand, .rightIndexProximal),
        ("L hand→middle1", .leftHand, .leftMiddleProximal),
        ("R thumb meta→prox", .rightThumbMetacarpal, .rightThumbProximal),
        ("R thumb prox→distal", .rightThumbProximal, .rightThumbDistal),
        ("R index 1→2", .rightIndexProximal, .rightIndexIntermediate), ("R index 2→3", .rightIndexIntermediate, .rightIndexDistal),
        ("R middle 1→2", .rightMiddleProximal, .rightMiddleIntermediate), ("R middle 2→3", .rightMiddleIntermediate, .rightMiddleDistal),
        ("R ring 1→2", .rightRingProximal, .rightRingIntermediate), ("R ring 2→3", .rightRingIntermediate, .rightRingDistal),
        ("R little 1→2", .rightLittleProximal, .rightLittleIntermediate), ("R little 2→3", .rightLittleIntermediate, .rightLittleDistal)
    ]

    @Test("Measure and render the phone clip when NL_PHONE_CLIP_DIAG_DIR is set")
    func measureAndRender() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_PHONE_CLIP_DIAG_DIR"], !path.isEmpty,
            let device = MTLCreateSystemDefaultDevice(),
            let thumbnails = VRMPartThumbnailRenderer(size: 768)
        else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let clipURL = try #require(Bundle.main.url(forResource: Self.clipName, withExtension: "vrma"))
        let reference = try ReferenceSkeleton(url: clipURL)
        var report = ""

        for character in ["Sonya", "Ekaterina"] {
            let modelURL = try #require(Bundle.main.url(forResource: character, withExtension: "vrm"))
            let model = try await VRMModel.load(from: modelURL, device: device)
            let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)
            let mirror = model.isVRM0
            report += "== \(character) (\(mirror ? "VRM 0.x" : "VRM 1.x")) clip \(String(format: "%.2f", clip.duration))s, \(clip.jointTracks.count) joint tracks\n"

            var worstBody: Float = 0
            var worstHand: Float = 0
            for time in Self.sampleTimes {
                pose(model, with: clip, at: time)
                let expected = reference.worldPositions(at: time)
                report += String(format: "-- t=%.1fs\n", time)
                for (label, from, to) in Self.bodySegments + Self.handSegments {
                    guard let error = segmentError(model, expected, from, to, mirror: mirror) else {
                        report += "   \(label): (missing)\n"
                        continue
                    }
                    let isHand = Self.handSegments.contains { $0.0 == label }
                    if isHand { worstHand = max(worstHand, error) } else { worstBody = max(worstBody, error) }
                    report += String(format: "   %@: %.1f°\n", label, error)
                }
                report += handPlacement(model, expected, mirror: mirror)
            }
            report += String(format: "   WORST body/spine/head: %.1f°   WORST hand/fingers: %.1f°\n\n", worstBody, worstHand)
            #expect(worstBody < 12, "\(character): body segments drift \(worstBody)°")

            for time in Self.renderTimes {
                pose(model, with: clip, at: time)
                guard let image = thumbnails.render(model: model, subject: .portrait), let png = image.pngData() else { continue }
                let name = "\(character.lowercased())_t\(String(format: "%04.1f", time).replacingOccurrences(of: ".", with: "_")).png"
                try png.write(to: outputDir.appendingPathComponent(name), options: .atomic)
            }
        }
        try report.write(to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Measurements

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

    /// Angle between the clip skeleton's segment direction and the model's.
    private func segmentError(
        _ model: VRMModel, _ expected: [VRMHumanoidBone: SIMD3<Float>],
        _ from: VRMHumanoidBone, _ to: VRMHumanoidBone, mirror: Bool
    ) -> Float? {
        guard let a = expected[from], let b = expected[to],
            let actualA = worldPosition(model, from), let actualB = worldPosition(model, to)
        else { return nil }
        var want = simd_normalize(b - a)
        if mirror { want = SIMD3(-want.x, want.y, -want.z) }
        let got = simd_normalize(actualB - actualA)
        return acos(min(1, max(-1, simd_dot(want, got)))) * 180 / .pi
    }

    /// Where the hands sit relative to the head, on the model and on the
    /// clip skeleton, normalized by the hips→head height of each so the two
    /// rigs' different sizes compare.
    private func handPlacement(_ model: VRMModel, _ expected: [VRMHumanoidBone: SIMD3<Float>], mirror: Bool) -> String {
        guard let head = worldPosition(model, .head), let hips = worldPosition(model, .hips),
            let rightHand = worldPosition(model, .rightHand), let leftHand = worldPosition(model, .leftHand),
            let refHead = expected[.head], let refHips = expected[.hips],
            let refRight = expected[.rightHand], let refLeft = expected[.leftHand]
        else { return "   hands: (missing)\n" }
        let height = max(head.y - hips.y, 0.01)
        let refHeight = max(refHead.y - refHips.y, 0.01)
        func line(_ label: String, _ hand: SIMD3<Float>, _ refHand: SIMD3<Float>) -> String {
            let got = (hand - head) / height
            var want = (refHand - refHead) / refHeight
            if mirror { want = SIMD3(-want.x, want.y, -want.z) }
            return String(
                format: "   %@ hand − head (÷ torso height): model (%.2f, %.2f, %.2f) |%.2f|   clip (%.2f, %.2f, %.2f) |%.2f|\n",
                label, got.x, got.y, got.z, simd_length(got), want.x, want.y, want.z, simd_length(want))
        }
        return line("R", rightHand, refRight) + line("L", leftHand, refLeft)
    }
}
