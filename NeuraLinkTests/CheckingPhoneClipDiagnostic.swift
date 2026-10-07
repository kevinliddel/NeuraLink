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
            let thumbnails = VRMPartThumbnailRenderer(size: 1536)
        else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let clipURL = try #require(Bundle.main.url(forResource: Self.clipName, withExtension: "vrma"))
        let reference = try ReferenceSkeleton(url: clipURL)
        let propURL = try #require(Bundle.main.url(forResource: VRMMetalState.phonePropName, withExtension: "glb"))
        let prop = try await VRMPropLoader.load(
            url: propURL, device: device, maxTextureSize: 512, rotatedMaterials: VRMMetalState.phonePropUpsideDownTextureMaterials)
        var report = ""

        for character in ["Sonya", "Ekaterina"] {
            let modelURL = try #require(Bundle.main.url(forResource: character, withExtension: "vrm"))
            let model = try await VRMModel.load(from: modelURL, device: device)
            let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)
            let mirror = model.isVRM0
            // The phone in hand, as the episode shows it — the renders are how
            // the grip constant gets tuned.
            let attachment = try model.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
            model.setProp(attachment, visible: true)
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
            report += String(format: "   WORST body/spine/head: %.1f°   WORST hand/fingers: %.1f°\n", worstBody, worstHand)
            pose(model, with: clip, at: 4)
            let (gripReport, derived) = suggestedGrip(model, mirror: mirror)
            report += gripReport + "\n"
            // Render with the derived grip so one run both proposes and shows it.
            model.setProp(attachment, visible: false)
            let derivedAttachment = try model.attachProp(prop, to: .rightHand, grip: derived)
            model.setProp(derivedAttachment, visible: true)
            #expect(worstBody < 12, "\(character): body segments drift \(worstBody)°")

            // Current grip: portrait and scene-camera framings at each render
            // time; derived grip: the same at the hold.
            model.setProp(derivedAttachment, visible: false)
            model.setProp(attachment, visible: true)
            for time in Self.renderTimes {
                pose(model, with: clip, at: time)
                let stem = "\(character.lowercased())_t\(String(format: "%04.1f", time).replacingOccurrences(of: ".", with: "_"))"
                try write(thumbnails.render(model: model, subject: .portrait), to: outputDir, name: stem)
                try write(thumbnails.render(model: model, subject: .figure), to: outputDir, name: stem + "_scene")
            }
            model.setProp(attachment, visible: false)
            model.setProp(derivedAttachment, visible: true)
            pose(model, with: clip, at: 4)
            try write(thumbnails.render(model: model, subject: .portrait), to: outputDir, name: "\(character.lowercased())_t04_0_derived")
            try write(thumbnails.render(model: model, subject: .figure), to: outputDir, name: "\(character.lowercased())_t04_0_derived_scene")
        }
        try report.write(to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    private func write(_ image: UIImage?, to directory: URL, name: String) throws {
        guard let png = image?.pngData() else { return }
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    // MARK: - Grip derivation

    /// The hand-local grip that, in this hold pose, points the screen at the
    /// face with the long axis along the thumb — expressed in the VRM 1.0
    /// hand frame the constant in VRMMetalState+PhoneEpisode uses, so both
    /// characters should print nearly the same numbers.
    private func suggestedGrip(
        _ model: VRMModel, mirror: Bool, upFromPalm: Float = 0.008, towardScreen: Float = 0.010, rollTowardFingers: Float = 12,
        tiltForward: Float = 45
    ) -> (String, VRMPropGrip) {
        let fallback = VRMMetalState.phoneGrip
        guard let handIndex = model.humanoid?.getBoneNode(.rightHand),
            let head = worldPosition(model, .head), let hand = worldPosition(model, .rightHand),
            let thumb = worldPosition(model, .rightThumbMetacarpal) ?? worldPosition(model, .rightThumbProximal)
        else { return ("   grip: (missing bones)\n", fallback) }
        let yaw: simd_quatf = mirror ? VRMModel.vrmVersionYaw : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let m = model.nodes[handIndex].worldMatrix
        let handBasis = float3x3(
            simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
            simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
            simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        let handRotation = simd_normalize(yaw * simd_quatf(handBasis))  // render space
        let toFace = simd_normalize(yaw.act(head - hand))
        let thumbDirection = simd_normalize(yaw.act(thumb - hand))
        // The reference hold: phone upright in the fist, top up, screen facing
        // the viewer with a slight tilt back toward her face, the lower third
        // gripped. After the loader's chain the file's +Z is the phone's BACK
        // (the camera bump), so the frame's +Z is the screen direction
        // negated. Long axis = world up within the screen plane (portrait,
        // top up); width completes the frame.
        // She is the one reading it: the screen faces up and back toward her
        // eyes, so the top of the phone leans AWAY from her, toward the
        // viewer, by `tiltForward` degrees from vertical (45° ≈ the screen
        // square to a gaze coming down at 45°). The viewer sees its back.
        let tilt = tiltForward * .pi / 180
        let screen = simd_normalize(SIMD3<Float>(0, cos(tilt), -sin(tilt)))
        // The file's −Z (after the loader's chain) is the screen side — the
        // camera module shows on +Z — and its +Y runs toward the BOTTOM of
        // the phone (verified on a 1536 px render: camera module at the top
        // end, back facing the camera, before the long axis was negated).
        let normal = -screen
        _ = toFace
        let up = SIMD3<Float>(0, 1, 0)
        var top = simd_normalize(up - simd_dot(up, normal) * normal)
        // A relaxed hold rolls the top a little toward the fingertips.
        let middleWorld = worldPosition(model, .rightMiddleProximal) ?? hand
        let fingers = simd_normalize(yaw.act(middleWorld - hand))
        let fingersInPlane = simd_normalize(fingers - simd_dot(fingers, normal) * normal)
        let roll = rollTowardFingers * .pi / 180
        top = simd_normalize(cos(roll) * top + sin(roll) * fingersInPlane)
        // The file's +Y (after the loader's chain) runs toward the BOTTOM of
        // the phone, so the long axis is the top direction negated.
        let long = -top
        let width = simd_normalize(simd_cross(long, normal))
        let phoneWorld = simd_quatf(float3x3(width, long, normal))  // file +X, +Y, +Z after the loader's chain
        // Hand-local in this rig's own frame; a 0.x rig's frame is the 1.0
        // frame yawed, so express it as the 1.0-frame constant resolved() expects.
        let local = simd_normalize(handRotation.inverse * phoneWorld)
        let grip = mirror ? simd_normalize(VRMModel.vrmVersionYaw * local) : local
        // Centre: the lower third sits in the fist — a little up the long axis
        // from the palm's centre and a touch toward the screen side, so the
        // fingers wrap the edges and the back rests on the palm.
        let middle = worldPosition(model, .rightMiddleProximal) ?? hand
        let palmCentre = hand + 0.5 * (middle - hand) + 0.3 * (thumb - hand)
        let renderYaw: simd_quatf = mirror ? VRMModel.vrmVersionYaw.inverse : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let centreWorld = palmCentre + upFromPalm * renderYaw.act(top) + towardScreen * renderYaw.act(screen)
        let centreLocal = handRotation.inverse.act(yaw.act(centreWorld - hand))
        let centre = mirror ? VRMModel.vrmVersionYaw.act(centreLocal) : centreLocal
        _ = thumbDirection
        let current = VRMMetalState.phoneGrip.rotation
        let currentScreen = handRotation.act(current.act(SIMD3<Float>(0, 0, -1)))
        let offAngle = acos(min(1, max(-1, simd_dot(currentScreen, toFace)))) * 180 / .pi
        let axes = ["X", "Y", "Z"].enumerated().map { index, name -> String in
            let axis = handRotation.act(SIMD3<Float>(index == 0 ? 1 : 0, index == 1 ? 1 : 0, index == 2 ? 1 : 0))
            return String(format: "%@(%.2f, %.2f, %.2f)", name, axis.x, axis.y, axis.z)
        }.joined(separator: " ")
        let text = String(
            format: "   hand axes in render space @4s: %@\n   current screen normal is %.0f° off the face\n"
                + "   suggested grip rotation (ix, iy, iz, r): (%.4f, %.4f, %.4f, %.4f)  angle %.1f° about (%.2f, %.2f, %.2f)\n"
                + "   suggested grip translation: (%.4f, %.4f, %.4f)\n",
            axes, offAngle, grip.imag.x, grip.imag.y, grip.imag.z, grip.real,
            grip.angle * 180 / .pi, grip.axis.x, grip.axis.y, grip.axis.z, centre.x, centre.y, centre.z)
        let text2 = text + String(format: "   (up %.3f, toward screen %.3f, roll %.0f°, tilt forward %.0f°)\n",
                                  upFromPalm, towardScreen, rollTowardFingers, tiltForward)
        return (text2, VRMPropGrip(translation: centre, rotation: grip, scale: fallback.scale))
    }

    // MARK: - Grip candidates contact sheet

    /// Named holds to choose between, all 85% size, centre on the palm.
    private static let gripCandidates: [(String, VRMPropGrip)] = [
        ("A_along_fingers_screen_up", VRMPropGrip(
            translation: SIMD3<Float>(-0.045, -0.012, 0.008), rotation: simd_quatf(ix: -0.5, iy: 0.5, iz: 0.5, r: 0.5), scale: 0.85)),
        ("B_along_thumb_screen_up", VRMPropGrip(
            translation: SIMD3<Float>(-0.035, -0.012, 0.015), rotation: simd_quatf(ix: 0, iy: 0.7071068, iz: 0.7071068, r: 0), scale: 0.85)),
        ("C_along_thumb_screen_to_viewer", VRMPropGrip(
            translation: SIMD3<Float>(-0.040, -0.007, 0.013), rotation: simd_quatf(ix: 0.4978, iy: 0.7388, iz: 0.4516, r: 0.0483), scale: 0.85)),
        ("D_upright_in_hollow", VRMPropGrip(
            translation: SIMD3<Float>(-0.016, -0.043, 0.006), rotation: simd_quatf(ix: 0.8995, iy: 0.1770, iz: 0.3856, r: -0.1044), scale: 0.85)),
        ("E_along_fingers_screen_to_palm_first_build", VRMPropGrip(
            translation: SIMD3<Float>(-0.045, -0.012, 0.008),
            rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)) * simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)),
            scale: 0.85)),
        ("F_along_fingers_standing_screen_to_viewer", VRMPropGrip(
            translation: SIMD3<Float>(-0.045, -0.030, 0.008), rotation: simd_quatf(ix: 0, iy: 0.7071068, iz: 0, r: 0.7071068), scale: 0.85))
    ]

    @Test("Render the grip candidates when NL_PHONE_GRIP_SHEET_DIR is set")
    func gripSheet() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_PHONE_GRIP_SHEET_DIR"], !path.isEmpty,
            let device = MTLCreateSystemDefaultDevice(),
            let thumbnails = VRMPartThumbnailRenderer(size: 768)
        else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let clipURL = try #require(Bundle.main.url(forResource: Self.clipName, withExtension: "vrma"))
        let propURL = try #require(Bundle.main.url(forResource: VRMMetalState.phonePropName, withExtension: "glb"))
        let prop = try await VRMPropLoader.load(
            url: propURL, device: device, maxTextureSize: 512, rotatedMaterials: VRMMetalState.phonePropUpsideDownTextureMaterials)
        for character in ["Sonya", "Ekaterina"] {
            let modelURL = try #require(Bundle.main.url(forResource: character, withExtension: "vrm"))
            let model = try await VRMModel.load(from: modelURL, device: device)
            let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)
            pose(model, with: clip, at: 4)
            // Variants of the reference hold: (up from palm, toward screen, roll°).
            let variants: [(String, Float, Float, Float)] = [
                ("G1_lower_behind_fingers", 0.022, -0.010, 0), ("G2_lower_behind_roll12", 0.022, -0.010, 12),
                ("G3_deeper_roll12", 0.015, -0.012, 12), ("G4_lower_behind_roll20", 0.020, -0.008, 20)
            ]
            let candidates: [(String, VRMPropGrip)] = ProcessInfo.processInfo.environment["NL_PHONE_GRIP_VARIANTS"] == nil
                ? Self.gripCandidates
                : variants.map { ($0.0, suggestedGrip(model, mirror: model.isVRM0, upFromPalm: $0.1, towardScreen: $0.2, rollTowardFingers: $0.3).1) }
            let attachments = try candidates.map { try model.attachProp(prop, to: .rightHand, grip: $0.1) }
            let numbers = candidates.map { name, grip -> String in
                String(format: "%@ %@: t(%.4f, %.4f, %.4f) q(%.4f, %.4f, %.4f, %.4f) s%.2f", character, name,
                       grip.translation.x, grip.translation.y, grip.translation.z,
                       grip.rotation.imag.x, grip.rotation.imag.y, grip.rotation.imag.z, grip.rotation.real, grip.scale)
            }.joined(separator: "\n") + "\n"
            try numbers.write(to: outputDir.appendingPathComponent("grips_\(character.lowercased()).txt"), atomically: true, encoding: .utf8)
            for (index, (name, _)) in candidates.enumerated() {
                for attachment in attachments { model.setProp(attachment, visible: false) }
                model.setProp(attachments[index], visible: true)
                let stem = "\(character.lowercased())_\(name)"
                try write(thumbnails.render(model: model, subject: .figure), to: outputDir, name: stem + "_scene")
                try write(thumbnails.render(model: model, subject: .portrait), to: outputDir, name: stem + "_above")
            }
        }
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
