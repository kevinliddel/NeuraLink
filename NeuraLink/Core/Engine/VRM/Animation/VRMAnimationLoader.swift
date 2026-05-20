//
//  VRMAnimationLoader.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

public enum VRMAnimationLoader {

    public static func loadVRMA(from url: URL, model: VRMModel? = nil) throws -> AnimationClip {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let buffer = BufferLoader(
            document: document, binaryData: binary,
            baseURL: url.deletingLastPathComponent())

        guard let animations = document.animations, !animations.isEmpty else {
            throw NSError(domain: "VRMAnimationLoader", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "No animations in VRMA"])
        }

        let anim = animations[0]
        var duration: Float = 0
        for sampler in anim.samplers {
            if let last = (try? buffer.loadAccessorAsFloat(sampler.input))?.last {
                duration = max(duration, last)
            }
        }
        if duration <= 0 { duration = 1.0 }

        var clip = AnimationClip(duration: duration)
        var nodeTracks: [Int: [String: KeyTrack]] = [:]

        for channel in anim.channels {
            guard channel.sampler < anim.samplers.count,
                  let nodeIndex = channel.target.node,
                  let componentCount = componentCountForPath(channel.target.path)
            else { continue }
            let sampler = anim.samplers[channel.sampler]
            let times  = try buffer.loadAccessorAsFloat(sampler.input)
            let values = try buffer.loadAccessorAsFloat(sampler.output)
            var node = nodeTracks[nodeIndex] ?? [:]
            node[channel.target.path] = KeyTrack(
                times: times, values: values,
                path: channel.target.path,
                interpolation: Interpolation(sampler.interpolation),
                componentCount: componentCount)
            nodeTracks[nodeIndex] = node
        }

        let animRestTransforms  = buildAnimationRestTransforms(document: document)
        let modelRestTransforms = buildModelRestTransforms(model: model)
        let convertForVRM0      = model?.isVRM0 ?? false

        let animationNodeToBone    = parseHumanoidBoneMap(from: document)
        let animationExpressionMap = parseExpressionNodeMap(from: document)
        let modelNameToBone        = buildModelNameToBoneMap(model: model)

        // Resolve bones for each node and check for metacarpals
        var resolvedBones: [Int: VRMHumanoidBone] = [:]
        for nodeIndex in nodeTracks.keys {
            let nodeName = document.nodes?[safe: nodeIndex]?.name ?? ""
            if let bone = resolveBone(nodeIndex: nodeIndex, nodeName: nodeName,
                                      animationNodeToBone: animationNodeToBone,
                                      modelNameToBone: modelNameToBone) {
                resolvedBones[nodeIndex] = bone
            }
        }

        let animHasLeftMetacarpal = resolvedBones.values.contains(.leftThumbMetacarpal)
        let animHasRightMetacarpal = resolvedBones.values.contains(.rightThumbMetacarpal)
        let modelHasLeftMetacarpal = modelRestTransforms[.leftThumbMetacarpal] != nil
        let modelHasRightMetacarpal = modelRestTransforms[.rightThumbMetacarpal] != nil
        let isTargetVRM1 = model != nil && !model!.isVRM0

        // Tracks nodes whose bone was remapped between metacarpal/proximal.
        // These skip modelRest to avoid stacking the T-pose spread on the animation delta.
        var remappedNodes = Set<Int>()

        for (nodeIndex, tracks) in nodeTracks {
            let nodeName = document.nodes?[safe: nodeIndex]?.name ?? ""
            var bone = resolvedBones[nodeIndex]

            // Thumb retargeting between the 3-joint VRM 1.x animation schema
            // (Metacarpal → Proximal → Distal) and the model's actual humanoid map.
            if isTargetVRM1, let b = bone {
                // Anim lacks metacarpal but model has it: the anim's proximal track
                // is the wrist-attached joint, so drive the model's metacarpal with it.
                if b == .leftThumbProximal && !animHasLeftMetacarpal && modelHasLeftMetacarpal {
                    bone = .leftThumbMetacarpal
                    remappedNodes.insert(nodeIndex)
                } else if b == .rightThumbProximal && !animHasRightMetacarpal && modelHasRightMetacarpal {
                    bone = .rightThumbMetacarpal
                    remappedNodes.insert(nodeIndex)
                }
                // Anim has metacarpal but model lacks it: the model's "proximal" is the
                // wrist-attached bone (VRM 0.x-style 2-joint thumb on a 1.x model). Drive it
                // with the anim's metacarpal track and drop the anim's proximal track —
                // otherwise both would compete for the same model bone and produce the
                // ~90° bent thumb seen with neutral.vrma on Sonya.
                else if b == .leftThumbMetacarpal && !modelHasLeftMetacarpal {
                    bone = .leftThumbProximal
                    remappedNodes.insert(nodeIndex)
                } else if b == .rightThumbMetacarpal && !modelHasRightMetacarpal {
                    bone = .rightThumbProximal
                    remappedNodes.insert(nodeIndex)
                } else if b == .leftThumbProximal && animHasLeftMetacarpal && !modelHasLeftMetacarpal {
                    continue
                } else if b == .rightThumbProximal && animHasRightMetacarpal && !modelHasRightMetacarpal {
                    continue
                }
            }

            if let bone {
                let isThumb = bone == .leftThumbMetacarpal || bone == .rightThumbMetacarpal
                    || bone == .leftThumbProximal || bone == .rightThumbProximal

                let animRest = animRestTransforms[nodeIndex] ?? .identity
                let rawModelRest: RestTransform? = remappedNodes.contains(nodeIndex)
                    ? nil
                    : modelRestTransforms[bone]
                // VRoid-exported VRM 1.x models bake a ~45° outward spread into the thumb
                // metacarpal's rest rotation. Standard retargeting (`modelRest * q`) stacks
                // that spread on top of the animation pose and bends the thumb at ~90°.
                // Pre-multiplying ~35° inward on the modelRest brings the resting bone to a
                // natural closed-thumb pose so animation deltas compose around it cleanly.
                let effectiveModelRest = applyVRoidThumbCompensation(
                    bone: bone, rest: rawModelRest, isVRM1: isTargetVRM1)

                // Diagnostic: log thumb quaternion values so we can derive the correct formula.
                if isThumb {
                    let aR = animRest.rotation
                    let mR = effectiveModelRest?.rotation
                    let firstQ = tracks["rotation"].flatMap { t -> simd_quatf? in
                        guard !t.times.isEmpty, t.values.count >= 4 else { return nil }
                        return simd_quatf(ix: t.values[0], iy: t.values[1],
                                         iz: t.values[2], r: t.values[3])
                    }
                    let remapped = remappedNodes.contains(nodeIndex)
                    nlLog("""
                        [ThumbDiag] bone=\(bone.rawValue) nodeIndex=\(nodeIndex) remapped=\(remapped)
                          animRest : ix=\(String(format: "%.4f", aR.imag.x)) iy=\(String(format: "%.4f", aR.imag.y)) iz=\(String(format: "%.4f", aR.imag.z)) r=\(String(format: "%.4f", aR.real))
                          modelRest: \(mR.map { "ix=\(String(format: "%.4f", $0.imag.x)) iy=\(String(format: "%.4f", $0.imag.y)) iz=\(String(format: "%.4f", $0.imag.z)) r=\(String(format: "%.4f", $0.real))" } ?? "nil")
                          firstKey : \(firstQ.map { "ix=\(String(format: "%.4f", $0.imag.x)) iy=\(String(format: "%.4f", $0.imag.y)) iz=\(String(format: "%.4f", $0.imag.z)) r=\(String(format: "%.4f", $0.real))" } ?? "no track")
                        """, level: .info)
                }

                clip.addJointTrack(makeJointTrack(
                    bone: bone, tracks: tracks,
                    animRest: animRest,
                    modelRest: effectiveModelRest,
                    convertForVRM0: convertForVRM0))
            } else {
                clip.addNodeTrack(makeNodeTrack(
                    nodeName: nodeName, tracks: tracks,
                    animRest: animRestTransforms[nodeIndex] ?? .identity,
                    convertForVRM0: convertForVRM0))
            }
        }

        for (expressionName, nodeIndex) in animationExpressionMap {
            guard let track = nodeTracks[nodeIndex]?["translation"] else { continue }
            let sampler = makeExpressionWeightSampler(track: track)
            clip.addMorphTrack(key: expressionName, sample: sampler)
            if let preset = VRMExpressionPreset(rawValue: expressionName) {
                clip.addExpressionTrack(ExpressionTrack(expression: preset, sampler: sampler))
            }
        }

        return clip
    }
}

// MARK: - Bone Resolution

private func resolveBone(
    nodeIndex: Int,
    nodeName: String,
    animationNodeToBone: [Int: VRMHumanoidBone],
    modelNameToBone: [String: VRMHumanoidBone]
) -> VRMHumanoidBone? {
    if let bone = animationNodeToBone[nodeIndex] { return bone }
    let norm = normalizeNodeName(nodeName)
    if let bone = modelNameToBone[norm] { return bone }
    if let (_, bone) = modelNameToBone.first(where: { k, _ in k.contains(norm) || norm.contains(k) }) {
        return bone
    }
    return VRMHumanoidBone.heuristic(for: nodeName)
}

// MARK: - Track Factories

private func makeJointTrack(
    bone: VRMHumanoidBone,
    tracks: [String: KeyTrack],
    animRest: RestTransform,
    modelRest: RestTransform?,
    convertForVRM0: Bool
) -> JointTrack {
    JointTrack(
        bone: bone,
        rotationSampler: tracks["rotation"].map {
            makeRotationSampler(track: $0, animRest: animRest.rotation,
                                modelRest: modelRest?.rotation,
                                convertForVRM0: convertForVRM0)
        },
        translationSampler: tracks["translation"].map {
            makeTranslationSampler(track: $0, animRest: animRest.translation,
                                   modelRest: modelRest?.translation, convertForVRM0: convertForVRM0)
        },
        scaleSampler: tracks["scale"].map {
            makeScaleSampler(track: $0, animRest: animRest.scale, modelRest: modelRest?.scale)
        }
    )
}

private func makeNodeTrack(
    nodeName: String,
    tracks: [String: KeyTrack],
    animRest: RestTransform,
    convertForVRM0: Bool
) -> NodeTrack {
    NodeTrack(
        nodeName: nodeName,
        rotationSampler: tracks["rotation"].map {
            makeRotationSampler(track: $0, animRest: animRest.rotation,
                                modelRest: nil, convertForVRM0: convertForVRM0)
        },
        translationSampler: tracks["translation"].map {
            makeTranslationSampler(track: $0, animRest: animRest.translation,
                                   modelRest: nil, convertForVRM0: convertForVRM0)
        },
        scaleSampler: tracks["scale"].map {
            makeScaleSampler(track: $0, animRest: animRest.scale, modelRest: nil)
        }
    )
}

// MARK: - Extension Parsing

private func parseHumanoidBoneMap(from document: GLTFDocument) -> [Int: VRMHumanoidBone] {
    guard let ext       = document.extensions?["VRMC_vrm_animation"] as? [String: Any],
          let humanoid  = ext["humanoid"] as? [String: Any],
          let humanBones = humanoid["humanBones"] as? [String: Any]
    else { return [:] }
    var map: [Int: VRMHumanoidBone] = [:]
    for (boneName, value) in humanBones {
        guard let bone  = VRMHumanoidBone(rawValue: boneName),
              let dict  = value as? [String: Any],
              let index = anyToInt(dict["node"])
        else { continue }
        map[index] = bone
    }
    return map
}

private func parseExpressionNodeMap(from document: GLTFDocument) -> [String: Int] {
    guard let ext         = document.extensions?["VRMC_vrm_animation"] as? [String: Any],
          let expressions = ext["expressions"] as? [String: Any]
    else { return [:] }
    var map: [String: Int] = [:]
    for key in ["preset", "custom"] {
        guard let section = expressions[key] as? [String: Any] else { continue }
        for (name, value) in section {
            if let dict = value as? [String: Any], let node = anyToInt(dict["node"]) {
                map[name] = node
            }
        }
    }
    return map
}

private func buildModelNameToBoneMap(model: VRMModel?) -> [String: VRMHumanoidBone] {
    guard let model, let humanoid = model.humanoid else { return [:] }
    var map: [String: VRMHumanoidBone] = [:]
    for bone in VRMHumanoidBone.allCases {
        guard let nodeIndex = humanoid.getBoneNode(bone),
              let name = model.nodes[safe: nodeIndex]?.name
        else { continue }
        map[normalizeNodeName(name)] = bone
    }
    return map
}

// MARK: - VRoid Thumb Compensation

/// VRoid-exported VRM 1.x models encode a ~45° outward thumb spread in the metacarpal's
/// node rotation while leaving the proximal/distal segments at near-identity rest — which
/// makes the thumb extend as a perfectly straight stick after standard retargeting.
/// Real thumbs aren't straight at rest: each joint carries a small flexion toward the palm.
/// We pre-multiply a small inward rotation onto each segment's rest so the resting bone
/// composes naturally with the animation.
///
/// The metacarpal closes around the local Z axis (the axis the VRoid spread is encoded
/// on). The proximal/distal use the local Y axis — their parent's ~103° spread rotation
/// reorients their frames so neither X nor Z lines up with anatomical flex; Y is what
/// remains as the bend-toward-palm axis on these segments in VRoid's rig.
///
/// Per-segment closure (degrees, all toward the palm):
///   metacarpal = 25°  (axis Z, sign -L/+R)  — closes the T-pose spread
///   proximal   = 15°  (axis Y, sign -L/+R)  — first-knuckle curl
///   distal     = 10°  (axis Y, sign -L/+R)  — natural tip flex
private func applyVRoidThumbCompensation(
    bone: VRMHumanoidBone, rest: RestTransform?, isVRM1: Bool
) -> RestTransform? {
    guard isVRM1, let rest else { return rest }
    let sign: Float
    let degrees: Float
    let axis: SIMD3<Float>
    switch bone {
    case .leftThumbMetacarpal:  sign = -1; degrees = 25; axis = SIMD3<Float>(0, 0, 1)
    case .rightThumbMetacarpal: sign = +1; degrees = 25; axis = SIMD3<Float>(0, 0, 1)
    case .leftThumbProximal:    sign = -1; degrees = 15; axis = SIMD3<Float>(0, 1, 0)
    case .rightThumbProximal:   sign = +1; degrees = 15; axis = SIMD3<Float>(0, 1, 0)
    case .leftThumbDistal:      sign = -1; degrees = 10; axis = SIMD3<Float>(0, 1, 0)
    case .rightThumbDistal:     sign = +1; degrees = 10; axis = SIMD3<Float>(0, 1, 0)
    default: return rest
    }
    // Skip the metacarpal correction for models whose rest is near-identity (no baked
    // T-pose spread to compensate) so we don't over-curl them. Proximal/distal always
    // get their small natural flex — the model rest there is near-identity by design.
    let isMetacarpal = bone == .leftThumbMetacarpal || bone == .rightThumbMetacarpal
    if isMetacarpal && abs(rest.rotation.real) > 0.97 { return rest }

    let correction = simd_quatf(angle: sign * degrees * .pi / 180.0, axis: axis)
    let corrected = simd_normalize(rest.rotation * correction)
    return RestTransform(rotation: corrected, translation: rest.translation, scale: rest.scale)
}

// MARK: - Utilities

func normalizeNodeName(_ name: String) -> String {
    name.lowercased().unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .reduce(into: "") { $0.append(Character($1)) }
}

func anyToInt(_ any: Any?) -> Int? {
    switch any {
    case let i as Int:    return i
    case let d as Double: return Int(d)
    case let s as String: return Int(s)
    default:              return nil
    }
}

func componentCountForPath(_ path: String) -> Int? {
    switch path {
    case "rotation":              return 4
    case "translation", "scale":  return 3
    default:                      return nil
    }
}
