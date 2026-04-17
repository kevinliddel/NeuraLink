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
    func parseBlendShapeMaster(_ dict: [String: Any]) throws -> VRMExpressions {
        let expressions = VRMExpressions()

        guard let blendShapeGroups = dict["blendShapeGroups"] as? [[String: Any]] else {
            return expressions
        }

        for group in blendShapeGroups {
            guard let name = group["name"] as? String else { continue }
            let presetName = group["presetName"] as? String ?? name
            var expression = VRMExpression(name: name)

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
                    let targetValue = bind["targetValue"] as? [Float],
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
}
