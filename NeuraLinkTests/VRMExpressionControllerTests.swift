//
//  VRMExpressionControllerTests.swift
//  NeuraLinkTests
//
//  Expression evaluation per VRMC_vrm-1.0: isBinary, the blink / look-at /
//  mouth overrides (block, blend), colour and texture transform binds as
//  base + Σ (target − base) × weight, custom expressions alongside presets,
//  and the parse of both VRM versions' expression data.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@Suite("VRM expression controller")
struct VRMExpressionControllerTests {

    private typealias Entry = VRMExpressionController.Entry

    private func expression(
        binary: Bool = false, blink: VRMExpressionOverrideType = .none, mouth: VRMExpressionOverrideType = .none
    ) -> VRMExpression {
        var expression = VRMExpression(name: "e")
        expression.isBinary = binary
        expression.overrideBlink = blink
        expression.overrideMouth = mouth
        return expression
    }

    @Test("isBinary snaps at 0.5")
    func binary() {
        let weights = VRMExpressionController.effectiveWeights([
            Entry(expression: expression(binary: true), preset: .happy, weight: 0.4),
            Entry(expression: expression(binary: true), preset: .sad, weight: 0.6)
        ])
        #expect(weights == [0, 1])
    }

    @Test("Block zeroes the blink; blend scales it by 1 − the blending weights")
    func overrides() {
        let blocked = VRMExpressionController.effectiveWeights([
            Entry(expression: expression(blink: .block), preset: .happy, weight: 0.3),
            Entry(expression: expression(), preset: .blink, weight: 1)
        ])
        #expect(blocked[1] == 0)
        let blended = VRMExpressionController.effectiveWeights([
            Entry(expression: expression(blink: .blend), preset: .happy, weight: 0.25),
            Entry(expression: expression(blink: .blend), preset: .relaxed, weight: 0.25),
            Entry(expression: expression(), preset: .blink, weight: 1)
        ])
        #expect(abs(blended[2] - 0.5) < 1e-6)
    }

    @Test("An expression never overrides its own kind; an overridden binary one switches off")
    func sameKindAndBinary() {
        let weights = VRMExpressionController.effectiveWeights([
            Entry(expression: expression(blink: .block), preset: .blink, weight: 1),
            Entry(expression: expression(), preset: .blinkLeft, weight: 1),
            Entry(expression: expression(mouth: .blend), preset: .happy, weight: 0.3),
            Entry(expression: expression(binary: true), preset: .aa, weight: 1)
        ])
        #expect(weights[1] == 1, "blink does not block blinkLeft")
        #expect(weights[3] == 0, "a binary mouth shape partly overridden is suppressed")
    }

    @Test("Colour and texture transform binds add their differences from the base")
    func additiveBinds() {
        let controller = VRMExpressionController()
        controller.setBaseMaterialColor(materialIndex: 0, type: .color, color: [1, 1, 1, 1])
        controller.setBaseTextureTransform(materialIndex: 0, VRMTextureTransform())
        var first = VRMExpression(name: "a")
        first.materialColorBinds = [VRMMaterialColorBind(material: 0, type: .color, targetValue: [0, 1, 1, 1])]
        first.textureTransformBinds = [VRMTextureTransformBind(material: 0, scale: [2, 2], offset: [0.5, 0])]
        var second = VRMExpression(name: "b")
        second.materialColorBinds = [VRMMaterialColorBind(material: 0, type: .color, targetValue: [1, 0, 1, 1])]
        controller.registerExpression(first, for: .happy)
        controller.registerExpression(second, for: .sad)
        controller.setExpressionWeight(.happy, weight: 0.5)
        controller.setExpressionWeight(.sad, weight: 0.5)

        let color = controller.getMaterialColorOverride(materialIndex: 0, type: .color)
        #expect(color.map { simd_distance($0, [0.5, 0.5, 1, 1]) < 1e-6 } == true, "\(String(describing: color))")
        let transform = controller.textureTransformOverride(forMaterial: 0)
        #expect(transform?.scale == SIMD2(1.5, 1.5) && transform?.offset == SIMD2(0.25, 0))
    }

    @Test("A custom expression adds to the presets instead of wiping them")
    func customAlongsidePresets() {
        let controller = VRMExpressionController()
        var smile = VRMExpression(name: "smile")
        smile.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 0, weight: 1)]
        var wink = VRMExpression(name: "wink")
        wink.morphTargetBinds = [VRMMorphTargetBind(node: 0, index: 1, weight: 1)]
        controller.registerExpression(smile, for: .happy)
        controller.registerCustomExpression(wink, name: "wink")
        controller.setExpressionWeight(.happy, weight: 1)
        controller.setCustomExpressionWeight("wink", weight: 1)
        #expect(controller.weightsForMesh(0, morphCount: 2) == [1, 1])
        controller.setExpressionWeight(.happy, weight: 0.5)
        #expect(controller.weightsForMesh(0, morphCount: 2) == [0.5, 1], "the wink survives a preset update")
    }

    @Test("Parse: 1.0 colour targets with inexact decimals, texture transform binds; 0.x binary, look presets, material values")
    func parse() throws {
        let vrm1 = """
        {"preset": {"happy": {"isBinary": true, "overrideBlink": "block",
          "materialColorBinds": [{"material": 0, "type": "color", "targetValue": [0.3, 0.6, 0.9, 1]}],
          "textureTransformBinds": [{"material": 1, "scale": [1.5, 1], "offset": [0.25, 0]}]}}}
        """
        let parser = VRMExtensionParser()
        let expressions1 = try parser.parseExpressions(
            try #require(JSONSerialization.jsonObject(with: Data(vrm1.utf8)) as? [String: Any]))
        let happy = try #require(expressions1.preset[.happy])
        #expect(happy.isBinary && happy.overrideBlink == .block)
        #expect(happy.materialColorBinds.first.map { simd_distance($0.targetValue, [0.3, 0.6, 0.9, 1]) < 1e-6 } == true)
        #expect(happy.textureTransformBinds.first?.scale == SIMD2(1.5, 1))

        let vrm0 = """
        {"blendShapeGroups": [
          {"name": "LookLeft", "presetName": "lookleft", "binds": []},
          {"name": "Joy", "presetName": "joy", "isBinary": true, "binds": [],
           "materialValues": [{"materialName": "Face", "propertyName": "_Color", "targetValue": [1, 0.5, 0.5, 1]},
                              {"materialName": "Face", "propertyName": "_MainTex_ST", "targetValue": [1, 1, 0.5, 0]}]}
        ]}
        """
        let expressions0 = try parser.parseBlendShapeMaster(
            try #require(JSONSerialization.jsonObject(with: Data(vrm0.utf8)) as? [String: Any]),
            materialNames: ["Body", "Face"])
        #expect(expressions0.preset[.lookLeft] != nil)
        let joy = try #require(expressions0.preset[.happy])
        #expect(joy.isBinary)
        let color = try #require(joy.materialColorBinds.first)
        #expect(color.material == 1 && abs(color.targetValue.y - 0.214) < 0.001, "sRGB 0.5 → linear 0.214")
        let uv = try #require(joy.textureTransformBinds.first)
        #expect(uv.scale == SIMD2(1, 1) && uv.offset == SIMD2(0.5, 0), "V offset flipped: 1 − 1 − 0")
    }
}
