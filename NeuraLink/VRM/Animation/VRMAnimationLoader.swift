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

        for (nodeIndex, tracks) in nodeTracks {
            let nodeName = document.nodes?[safe: nodeIndex]?.name ?? ""
            let bone = resolveBone(nodeIndex: nodeIndex, nodeName: nodeName,
                                   animationNodeToBone: animationNodeToBone,
                                   modelNameToBone: modelNameToBone)
            if let bone {
                clip.addJointTrack(makeJointTrack(
                    bone: bone, tracks: tracks,
                    animRest: animRestTransforms[nodeIndex] ?? .identity,
                    modelRest: modelRestTransforms[bone],
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
    return heuristicBone(for: nodeName)
}

private func heuristicBone(for name: String) -> VRMHumanoidBone? {
    let n = name.lowercased()
    let isLeft  = n.contains("_l_") || n.contains("left")
    let isRight = n.contains("_r_") || n.contains("right")
    if n.contains("hips") { return .hips }
    if n.contains("upperchest") || (n.contains("upper") && n.contains("chest")) { return .upperChest }
    if n.contains("chest") { return .chest }
    if n.contains("spine") { return .spine }
    if n.contains("neck") { return .neck }
    if n.contains("head") { return .head }
    if isLeft {
        if n.contains("upperarm") { return .leftUpperArm }
        if n.contains("lowerarm") { return .leftLowerArm }
        if n.contains("hand") && !n.contains("arm") { return .leftHand }
        if n.contains("shoulder") { return .leftShoulder }
        if n.contains("upperleg") { return .leftUpperLeg }
        if n.contains("lowerleg") { return .leftLowerLeg }
        if n.contains("foot") { return .leftFoot }
        if n.contains("toe") { return .leftToes }
    }
    if isRight {
        if n.contains("upperarm") { return .rightUpperArm }
        if n.contains("lowerarm") { return .rightLowerArm }
        if n.contains("hand") && !n.contains("arm") { return .rightHand }
        if n.contains("shoulder") { return .rightShoulder }
        if n.contains("upperleg") { return .rightUpperLeg }
        if n.contains("lowerleg") { return .rightLowerLeg }
        if n.contains("foot") { return .rightFoot }
        if n.contains("toe") { return .rightToes }
    }
    return nil
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
                                modelRest: modelRest?.rotation, convertForVRM0: convertForVRM0)
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
