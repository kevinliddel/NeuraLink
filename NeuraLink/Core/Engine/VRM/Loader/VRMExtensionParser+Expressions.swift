//
// VRMExtensionParser+Expressions.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import simd

// MARK: - Expression Parsing

extension VRMExtensionParser {
    func parseBlendShapeMaster(_ dict: [String: Any], materialNames: [String] = []) throws -> VRMExpressions {
        let expressions = VRMExpressions()

        guard let blendShapeGroups = dict["blendShapeGroups"] as? [[String: Any]] else {
            return expressions
        }

        for group in blendShapeGroups {
            guard let name = group["name"] as? String else { continue }
            let presetName = group["presetName"] as? String ?? name
            var expression = VRMExpression(name: name)
            expression.isBinary = group["isBinary"] as? Bool ?? false
            if let values = group["materialValues"] as? [[String: Any]] {
                appendVRM0MaterialValues(values, materialNames: materialNames, to: &expression)
            }

            if let binds = group["binds"] as? [[String: Any]] {
                for bind in binds {
                    let weightField = bind["weight"]
                    if weightField == nil || weightField is NSNull { continue }

                    var weightValue: Float?
                    if let w = weightField as? Float {
                        weightValue = w
                    } else if let w = weightField as? Double {
                        weightValue = Float(w)
                    } else if let w = weightField as? Int {
                        weightValue = Float(w)
                    }

                    if let mesh = bind["mesh"] as? Int,
                        let index = bind["index"] as? Int,
                        let weight = weightValue {
                        expression.morphTargetBinds.append(
                            VRMMorphTargetBind(
                                node: mesh,
                                index: index,
                                // VRM 0.0 uses 0-100, VRM 1.0 uses 0-1
                                weight: weight / 100.0
                            )
                        )
                    }
                }
            }

            if let preset = mapVRM0PresetToVRM1(presetName) {
                expressions.preset[preset] = expression
            } else {
                expressions.custom[name] = expression
            }
        }

        // Cross-version compatibility: Synthesize 'Surprise' for VRM 0.x models
        // VRM 0.0 standard doesn't have a 'Surprise' preset, so we map it to 'Joy'
        // (or 'Fun' in 0.0 terms) to provide a reasonable fallback for AI interactions.
        if expressions.preset[.surprised] == nil {
            if let joy = expressions.preset[.happy] {
                expressions.preset[.surprised] = joy
            }
        }

        return expressions
    }

    func mapVRM0PresetToVRM1(_ presetName: String) -> VRMExpressionPreset? {
        switch presetName.lowercased() {
        case "neutral": return .neutral
        case "joy", "happy": return .happy
        case "angry": return .angry
        case "sorrow", "sad": return .sad
        case "fun", "relaxed": return .relaxed
        case "surprised": return .surprised
        case "blink": return .blink
        case "blink_l": return .blinkLeft
        case "blink_r": return .blinkRight
        case "a": return .aa
        case "i": return .ih
        case "u": return .ou
        case "e": return .ee
        case "o": return .oh
        case "lookup": return .lookUp
        case "lookdown": return .lookDown
        case "lookleft": return .lookLeft
        case "lookright": return .lookRight
        default: return nil
        }
    }

    func parseExpressions(_ dict: [String: Any]) throws -> VRMExpressions {
        let expressions = VRMExpressions()

        if let presetDict = dict["preset"] as? [String: Any] {
            for (presetName, expressionData) in presetDict {
                guard let preset = VRMExpressionPreset(rawValue: presetName),
                    let expressionDict = expressionData as? [String: Any]
                else { continue }
                expressions.preset[preset] = try parseExpression(expressionDict, name: presetName)
            }
        }

        if let customDict = dict["custom"] as? [String: Any] {
            for (customName, expressionData) in customDict {
                guard let expressionDict = expressionData as? [String: Any] else { continue }
                expressions.custom[customName] = try parseExpression(
                    expressionDict, name: customName)
            }
        }

        return expressions
    }

    func parseExpression(_ dict: [String: Any], name: String) throws -> VRMExpression {
        var expression = VRMExpression(name: name)
        expression.isBinary = dict["isBinary"] as? Bool ?? false

        if let morphTargetBinds = dict["morphTargetBinds"] as? [[String: Any]] {
            for bind in morphTargetBinds {
                guard let node = bind["node"] as? Int,
                    let index = bind["index"] as? Int,
                    let weight = parseFloatValue(bind["weight"])
                else { continue }
                expression.morphTargetBinds.append(
                    VRMMorphTargetBind(node: node, index: index, weight: weight))
            }
        }

        if let materialColorBinds = dict["materialColorBinds"] as? [[String: Any]] {
            for bind in materialColorBinds {
                guard let material = bind["material"] as? Int,
                    let typeStr = bind["type"] as? String,
                    let type = VRMMaterialColorType(rawValue: typeStr),
                    let targetValue = parseFloatArray(bind["targetValue"]),
                    targetValue.count == 4
                else { continue }
                expression.materialColorBinds.append(
                    VRMMaterialColorBind(
                        material: material,
                        type: type,
                        targetValue: SIMD4<Float>(
                            targetValue[0], targetValue[1], targetValue[2], targetValue[3])
                    )
                )
            }
        }

        if let textureTransformBinds = dict["textureTransformBinds"] as? [[String: Any]] {
            for bind in textureTransformBinds {
                guard let material = bind["material"] as? Int else { continue }
                let scale = parseFloatArray(bind["scale"]).flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
                let offset = parseFloatArray(bind["offset"]).flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
                expression.textureTransformBinds.append(
                    VRMTextureTransformBind(material: material, scale: scale ?? SIMD2(1, 1), offset: offset ?? .zero))
            }
        }

        if let s = dict["overrideBlink"] as? String {
            expression.overrideBlink = VRMExpressionOverrideType(rawValue: s) ?? .none
        }
        if let s = dict["overrideLookAt"] as? String {
            expression.overrideLookAt = VRMExpressionOverrideType(rawValue: s) ?? .none
        }
        if let s = dict["overrideMouth"] as? String {
            expression.overrideMouth = VRMExpressionOverrideType(rawValue: s) ?? .none
        }

        return expression
    }

    /// VRM 0.x `materialValues`: colours by Unity property name (sRGB, as
    /// the material parse reads them) and `_MainTex_ST` [scaleX, scaleY,
    /// offsetX, offsetY] in Unity's bottom-left UV space, flipped into glTF's
    /// as UniVRM's 1.0 migration does.
    func appendVRM0MaterialValues(
        _ values: [[String: Any]], materialNames: [String], to expression: inout VRMExpression
    ) {
        let colorTypes: [String: VRMMaterialColorType] = [
            "_Color": .color, "_ShadeColor": .shadeColor, "_EmissionColor": .emissionColor,
            "_RimColor": .rimColor, "_OutlineColor": .outlineColor
        ]
        func linear(_ value: Float) -> Float {
            value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for value in values {
            guard let name = value["materialName"] as? String, let material = materialNames.firstIndex(of: name),
                  let property = value["propertyName"] as? String,
                  let target = parseFloatArray(value["targetValue"]), target.count == 4 else { continue }
            if let type = colorTypes[property] {
                expression.materialColorBinds.append(VRMMaterialColorBind(
                    material: material, type: type,
                    targetValue: SIMD4(linear(target[0]), linear(target[1]), linear(target[2]), target[3])))
            } else if property == "_MainTex_ST" {
                expression.textureTransformBinds.append(VRMTextureTransformBind(
                    material: material, scale: SIMD2(target[0], target[1]),
                    offset: SIMD2(target[2], 1 - target[3] - target[1])))
            }
        }
    }
}
