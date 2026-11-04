//
//  PhoneGripDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: the phone in each character's right hand at the
//  checking_phone hold (t = 4 s), so a grip change can be judged on every
//  rig, not only the two it was tuned on. Renders a close-up of the hand
//  and the upper body from the scene camera's side, and reports each hand's
//  size and palm centre beside Sonya's. Set NL_PHONE_GRIP_DIR to run;
//  NL_PHONE_GRIP_MODELS adds colon-separated .vrm paths;
//  NL_PHONE_GRIP_OUTFITS dresses characters as on a device, e.g.
//  "Oz=casual_boy__outfit,Ekaterina=maid__outfit" (library parts, grafted
//  after the phone is attached, as the app does).
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Metal
import Testing
import simd
@testable import NeuraLink

@MainActor
@Suite("Phone grip diagnostic", .serialized)
struct PhoneGripDiagnostic {

    static let holdTime: Float = 4

    @Test("Render the phone grip on every character when NL_PHONE_GRIP_DIR is set")
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NL_PHONE_GRIP_DIR"], !path.isEmpty, let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls = ["Sonya", "Ekaterina", "Oz"].compactMap { Bundle.main.url(forResource: $0, withExtension: "vrm") }
        urls += (env["NL_PHONE_GRIP_MODELS"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let clipURL = try #require(Bundle.main.url(forResource: "checking_phone", withExtension: "vrma"))
        let propURL = try #require(Bundle.main.url(forResource: VRMMetalState.phonePropName, withExtension: "glb"))
        let prop = try await VRMPropLoader.load(
            url: propURL, device: device, maxTextureSize: 512,
            rotatedMaterials: VRMMetalState.phonePropUpsideDownTextureMaterials)

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 4))
        renderer.skyRenderer = nil
        renderer.terrainRenderer = nil
        renderer.environmentRenderer = nil
        renderer.enableSpringBone = false
        renderer.materialTimeOverride = 0
        renderer.setLight(0, direction: [0.25, -0.35, -0.90], color: [1.00, 0.99, 0.97], intensity: 0.95)
        renderer.setLight(1, direction: [-0.45, -0.15, -0.85], color: [0.88, 0.90, 0.96], intensity: 0.55)
        renderer.setLight(2, direction: [0.0, 0.75, -0.65], color: [0.95, 0.95, 1.00], intensity: 0.45)
        renderer.setAmbientColor(SIMD3<Float>(repeating: 0.42))

        // The palm the shipped grip was tuned on, measured fresh, so a run
        // both shows the palm-carried grip and prints the reference values.
        let sonyaURL = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let reference = try #require(VRMPalm.measure(in: try await VRMModel.load(from: sonyaURL), hand: .rightHand))
        var report = String(
            format: "Sonya palm: origin (%.5f, %.5f, %.5f) rotation (%.5f, %.5f, %.5f, %.5f) size %.5f\n",
            reference.origin.x, reference.origin.y, reference.origin.z, reference.rotation.imag.x,
            reference.rotation.imag.y, reference.rotation.imag.z, reference.rotation.real, reference.size)
        report += "model\tversion\thandLength_mm\tpalmWidth_mm\tpalmCentre_local_mm\tphoneCentre_from_palm_mm\n"
        var outfits: [String: String] = [:]
        for pair in (env["NL_PHONE_GRIP_OUTFITS"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2 { outfits[String(parts[0])] = String(parts[1]) }
        }
        var boneGrip = VRMMetalState.phoneGrip
        boneGrip.authoredOn = nil
        var palmGrip = boneGrip
        palmGrip.authoredOn = reference
        for url in urls {
            for (variant, grip) in [("bone", boneGrip), ("palm", palmGrip), ("fit", palmGrip)] {
                let name = url.deletingPathExtension().lastPathComponent
                let model = try await VRMModel.load(from: url, device: device)
                let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: model)
                let attachment = try model.attachProp(prop, to: .rightHand, grip: grip)
                if let stem = outfits[name], let item = PartsLibrary.shared.item(slug: "lib:\(stem)") {
                    let donor = try await VRMModel.load(from: try await item.resolvedURL(), device: device)
                    _ = try VRMPartGrafter.graft(.outfit, from: donor, donorSlug: item.donorSlug, onto: model)
                }
                model.setProp(attachment, visible: true)
                Self.pose(model, clip, at: Self.holdTime)
                if variant == "fit", let start = attachment.baseGrip, let box = VRMPropSeat.box(of: prop) {
                    // The app's own path: fingers at the hold, seat, reseat.
                    let holding = VRMMetalState.fingerPose(of: clip, at: VRMMetalState.phoneHoldTime, hand: .rightHand)
                    model.seatProp(attachment, holding: holding)
                    let fitted = attachment.handGrip ?? start
                    let seat = VRMPropSeat(points: VRMPropSeat.handPoints(in: model, hand: .rightHand), box: box)
                    let before = seat.score(start, from: start), after = seat.score(fitted, from: start)
                    report += String(
                        format: "  %@ fit: %d skin points, depth %.1f → %.1f, floating %.1f → %.1f, overhang %.1f → %.1f, moved %.1f mm, turned %.1f°\n",
                        name, seat.points.count, before.depth, after.depth, before.floating, after.floating,
                        before.overhang, after.overhang, after.shift, after.turn)
                    report += String(
                        format: "    seated grip: translation (%.5f, %.5f, %.5f) rotation (%.5f, %.5f, %.5f, %.5f) scale %.4f\n",
                        fitted.translation.x, fitted.translation.y, fitted.translation.z, fitted.rotation.imag.x,
                        fitted.rotation.imag.y, fitted.rotation.imag.z, fitted.rotation.real, fitted.scale)
                }
                report += "\(variant)\t" + Self.measure(model, name: name, attachment: attachment)
                if variant == "palm" { report += Self.visibleHand(model, name: name) }

                renderer.loadModel(model)
                renderer.isModelVisible = true
                renderer.lookAtController?.enabled = false
                let toRender = renderer.vrmVersionRotation
                func renderPoint(_ bone: VRMHumanoidBone) -> SIMD3<Float>? {
                    guard let index = model.humanoid?.getBoneNode(bone) else { return nil }
                    let world = toRender * SIMD4<Float>(model.nodes[index].worldPosition, 1)
                    return SIMD3(world.x, world.y, world.z)
                }
                guard let hand = renderPoint(.rightHand), let chest = renderPoint(.chest) ?? renderPoint(.spine) else { continue }
                let palm = renderPoint(.rightMiddleProximal).map { (hand + $0) * 0.5 } ?? hand
                let shots: [(String, SIMD3<Float>, SIMD3<Float>)] = [
                    ("hand", palm + [0.05, 0.04, 0.30], palm),
                    ("handSide", palm + [0.30, 0.05, 0.08], palm),
                    ("handTop", palm + [0.06, 0.38, 0.22], palm),
                    ("upper", chest + [0, 0.12, 1.25], chest + [0, 0.12, 0])
                ]
                for (shot, eye, target) in shots {
                    renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: eye, target: target, up: [0, 1, 0])
                    renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)
                    let png = try #require(VRMRenderSnapshots.render(renderer, device: device, samples: 4))
                    try png.write(to: dir.appendingPathComponent("\(name)_\(shot)_\(variant).png"))
                }
                renderer.clearModel()
            }
        }
        try report.write(to: dir.appendingPathComponent("phone_grip.tsv"), atomically: true, encoding: .utf8)
    }

    /// The drawn hand, from skin weighted ≥ 80% to the hand bone (its
    /// inverse bind matrix puts it in the hand's frame, whatever the pose
    /// or graft), in the bone-measured palm axes: x toward the fingers, y
    /// out of the palm, z across. 5th/95th percentiles, mm.
    private static func visibleHand(_ model: VRMModel, name: String) -> String {
        guard let handIndex = model.humanoid?.getBoneNode(.rightHand), let hand = model.nodes[safe: handIndex],
              let palm = VRMPalm.measure(in: model, hand: .rightHand) else { return "" }
        var points: [SIMD3<Float>] = []
        for node in model.nodes {
            guard let meshIndex = node.mesh, let skinIndex = node.skin, skinIndex < model.skins.count,
                  meshIndex < model.meshes.count else { continue }
            let skin = model.skins[skinIndex]
            guard let joint = skin.joints.firstIndex(where: { $0 === hand }), joint < skin.inverseBindMatrices.count
            else { continue }
            let toHand = skin.inverseBindMatrices[joint]
            for primitive in model.meshes[meshIndex].primitives
            where !model.hiddenPrimitives.contains(ObjectIdentifier(primitive)) {
                guard let buffer = primitive.vertexBuffer else { continue }
                let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                for index in 0..<primitive.vertexCount {
                    let vertex = vertices[index]
                    var weight: Float = 0
                    for slot in 0..<4 where Int(vertex.joints[slot]) == joint { weight += vertex.weights[slot] }
                    guard weight >= 0.8 else { continue }
                    let local = toHand * SIMD4<Float>(vertex.position, 1)
                    points.append(palm.rotation.inverse.act(SIMD3(local.x, local.y, local.z) - palm.origin))
                }
            }
        }
        guard points.count > 10 else { return "  visible hand: \(points.count) vertices\n" }
        func range(_ axis: KeyPath<SIMD3<Float>, Float>) -> (Float, Float) {
            let values = points.map { $0[keyPath: axis] }.sorted()
            return (values[values.count * 5 / 100] * 1000, values[values.count * 95 / 100] * 1000)
        }
        let along = range(\.x), out = range(\.y), across = range(\.z)
        return String(
            format: "  %@ visible hand (%d verts): along %.1f…%.1f  out-of-palm %.1f…%.1f  across %.1f…%.1f  (bone size %.1f)\n",
            name, points.count, along.0, along.1, out.0, out.1, across.0, across.1, palm.size * 1000)
    }

    static func pose(_ model: VRMModel, _ clip: AnimationClip, at time: Float) {
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

    private static func measure(_ model: VRMModel, name: String, attachment: VRMPropAttachment) -> String {
        func node(_ bone: VRMHumanoidBone) -> VRMNode? {
            model.humanoid?.getBoneNode(bone).flatMap { model.nodes[safe: $0] }
        }
        guard let hand = node(.rightHand), let middle = node(.rightMiddleProximal),
              let index = node(.rightIndexProximal), let little = node(.rightLittleProximal),
              let thumb = node(.rightThumbMetacarpal) ?? node(.rightThumbProximal),
              let phone = attachment.nodes.first
        else { return "\(name)\t(missing bones)\n" }
        let inverse = simd_inverse(hand.worldMatrix)
        func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let value = inverse * SIMD4<Float>(point, 1)
            return SIMD3(value.x, value.y, value.z)
        }
        let palmCentre = hand.worldPosition + 0.5 * (middle.worldPosition - hand.worldPosition)
            + 0.3 * (thumb.worldPosition - hand.worldPosition)
        let palmLocal = local(palmCentre) * 1000
        let phoneOffset = simd_distance(phone.worldPosition, palmCentre) * 1000
        return String(
            format: "%@\t%@\t%.1f\t%.1f\t(%.1f, %.1f, %.1f)\t%.1f\n", name, model.isVRM0 ? "0.x" : "1.0",
            simd_distance(hand.worldPosition, middle.worldPosition) * 1000,
            simd_distance(index.worldPosition, little.worldPosition) * 1000,
            palmLocal.x, palmLocal.y, palmLocal.z, phoneOffset)
    }
}
