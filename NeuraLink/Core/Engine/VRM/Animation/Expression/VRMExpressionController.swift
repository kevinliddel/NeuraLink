//
//  VRMExpressionController.swift
//  NeuraLink
//
//  Expression weights → morph weights, material colours and UV transforms,
//  per VRMC_vrm-1.0 expressions (VRM 0.x blend shape groups are parsed into
//  the same shape):
//
//  1. Each expression's weight; `isBinary` snaps it to 0 or 1 at 0.5.
//  2. Overrides: an expression with `overrideBlink` / `overrideLookAt` /
//     `overrideMouth` = block zeroes the procedural blink / look-at / mouth
//     expressions while it is on; = blend scales them by 1 − (sum of the
//     blending weights). An expression never overrides its own kind, and an
//     overridden binary expression is switched off outright.
//  3. Morph binds add weight × bind weight. Colour binds and texture
//     transform binds add their difference from the material's own value:
//     base + Σ (target − base) × weight.
//
//  Presets and custom expressions (VRMA tracks, imported models) are kept
//  side by side and evaluated together on every change.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import QuartzCore
import simd

public class VRMExpressionController: @unchecked Sendable {
    private var expressions: [VRMExpressionPreset: VRMExpression] = [:]
    private var customExpressions: [String: VRMExpression] = [:]
    private var currentWeights: [VRMExpressionPreset: Float] = [:]
    private var customWeights: [String: Float] = [:]
    private var morphTargetSystem: VRMMorphTargetSystem?
    private var animationTimer: Timer?
    private var meshMorphWeights: [Int: [Float]] = [:]
    private var materialColorOverrides: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]
    private var baseMaterialColors: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]
    private var baseTextureTransforms: [Int: VRMTextureTransform] = [:]
    private var textureTransformOverrides: [Int: VRMTextureTransform] = [:]

    static let blinkPresets: Set<VRMExpressionPreset> = [.blink, .blinkLeft, .blinkRight]
    static let lookAtPresets: Set<VRMExpressionPreset> = [.lookUp, .lookDown, .lookLeft, .lookRight]
    static let mouthPresets: Set<VRMExpressionPreset> = [.aa, .ih, .ou, .ee, .oh]

    public init() {
        for preset in VRMExpressionPreset.allCases {
            currentWeights[preset] = 0
        }
    }

    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    public func setMorphTargetSystem(_ system: VRMMorphTargetSystem) {
        morphTargetSystem = system
    }

    /// Forgets the previous model's expressions, weights and colours. Its
    /// binds name meshes and materials by index, so a preset the next model
    /// lacks would otherwise drive the next model's meshes with them.
    public func reset() {
        animationTimer?.invalidate()
        animationTimer = nil
        expressions.removeAll()
        customExpressions.removeAll()
        for preset in VRMExpressionPreset.allCases { currentWeights[preset] = 0 }
        customWeights.removeAll()
        meshMorphWeights.removeAll()
        materialColorOverrides.removeAll()
        baseMaterialColors.removeAll()
        baseTextureTransforms.removeAll()
        textureTransformOverrides.removeAll()
    }

    public func registerExpression(_ expression: VRMExpression, for preset: VRMExpressionPreset) {
        expressions[preset] = expression
    }

    public func registerCustomExpression(_ expression: VRMExpression, name: String) {
        customExpressions[name] = expression
    }

    // MARK: - Material colours and UV transforms

    public func setBaseMaterialColor(
        materialIndex: Int, type: VRMMaterialColorType, color: SIMD4<Float>
    ) {
        baseMaterialColors[materialIndex, default: [:]][type] = color
    }

    public func getMaterialColorOverride(
        materialIndex: Int, type: VRMMaterialColorType
    ) -> SIMD4<Float>? {
        return materialColorOverrides[materialIndex]?[type]
    }

    /// The material's own UV transform, which texture transform binds move from.
    public func setBaseTextureTransform(materialIndex: Int, _ transform: VRMTextureTransform) {
        baseTextureTransforms[materialIndex] = transform
    }

    /// The UV transform the active expressions give the material, if any.
    public func textureTransformOverride(forMaterial materialIndex: Int) -> VRMTextureTransform? {
        textureTransformOverrides[materialIndex]
    }

    // MARK: - Expression Weights

    public func setExpressionWeight(_ preset: VRMExpressionPreset, weight: Float) {
        currentWeights[preset] = clamp(weight, min: 0, max: 1)
        evaluate()
    }

    public func setCustomExpressionWeight(_ name: String, weight: Float) {
        guard customExpressions[name] != nil else { return }
        customWeights[name] = clamp(weight, min: 0, max: 1)
        evaluate()
    }

    public func setCustomExpressionWeights(_ weights: [String: Float]) {
        for (name, weight) in weights where customExpressions[name] != nil {
            customWeights[name] = clamp(weight, min: 0, max: 1)
        }
        evaluate()
    }

    public func weightsForMesh(_ meshIndex: Int, morphCount: Int) -> [Float] {
        guard morphCount > 0 else { return [] }
        let arr = meshMorphWeights[meshIndex] ?? []
        if arr.count >= morphCount { return Array(arr.prefix(morphCount)) }
        return arr + Array(repeating: 0.0, count: morphCount - arr.count)
    }

    // MARK: - Presets

    public func blink(duration: Float = 0.15, completion: (@Sendable () -> Void)? = nil) {
        animateExpression(.blink, to: 1.0, duration: duration) { [weak self] in
            self?.animateExpression(.blink, to: 0.0, duration: duration, completion: completion)
        }
    }

    public func setMood(_ mood: VRMExpressionPreset, intensity: Float = 1.0) {
        let moodExpressions: [VRMExpressionPreset] = [.happy, .angry, .sad, .relaxed, .surprised]
        for expr in moodExpressions where expr != mood { setExpressionWeight(expr, weight: 0) }
        setExpressionWeight(mood, weight: intensity)
    }

    public func speak(duration: Float = 2.0) {
        animateExpression(.aa, to: 0.8, duration: duration * 0.5) { [weak self] in
            self?.animateExpression(.aa, to: 0, duration: duration * 0.5)
        }
    }

    // MARK: - Evaluation

    /// One active expression: what it is, its preset (nil: custom), weight.
    struct Entry {
        let expression: VRMExpression
        let preset: VRMExpressionPreset?
        let weight: Float
    }

    /// The weight each entry applies after `isBinary` and the overrides.
    static func effectiveWeights(_ entries: [Entry]) -> [Float] {
        var weights = entries.map { entry -> Float in
            entry.expression.isBinary ? (entry.weight > 0.5 ? 1 : 0) : clamp(entry.weight, min: 0, max: 1)
        }
        func factor(_ kind: Set<VRMExpressionPreset>, _ override: (VRMExpression) -> VRMExpressionOverrideType) -> Float {
            var blend: Float = 0
            for (index, entry) in entries.enumerated() where weights[index] > 0 {
                if let preset = entry.preset, kind.contains(preset) { continue }
                switch override(entry.expression) {
                case .block: return 0
                case .blend: blend += weights[index]
                case .none: break
                }
            }
            return 1 - clamp(blend, min: 0, max: 1)
        }
        let factors: [(Set<VRMExpressionPreset>, Float)] = [
            (blinkPresets, factor(blinkPresets) { $0.overrideBlink }),
            (lookAtPresets, factor(lookAtPresets) { $0.overrideLookAt }),
            (mouthPresets, factor(mouthPresets) { $0.overrideMouth })
        ]
        for (index, entry) in entries.enumerated() {
            guard let preset = entry.preset,
                  let factor = factors.first(where: { $0.0.contains(preset) })?.1, factor < 1 else { continue }
            weights[index] = entry.expression.isBinary ? 0 : weights[index] * factor
        }
        return weights
    }

    private func evaluate() {
        var entries: [Entry] = []
        for (preset, weight) in currentWeights where weight > 0 {
            if let expression = expressions[preset] { entries.append(Entry(expression: expression, preset: preset, weight: weight)) }
        }
        for (name, weight) in customWeights where weight > 0 {
            if let expression = customExpressions[name] { entries.append(Entry(expression: expression, preset: nil, weight: weight)) }
        }
        let weights = Self.effectiveWeights(entries)

        meshMorphWeights.removeAll()
        var colorDeltas: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]
        var scaleDeltas: [Int: SIMD2<Float>] = [:]
        var offsetDeltas: [Int: SIMD2<Float>] = [:]
        for (entry, weight) in zip(entries, weights) where weight > 0 {
            applyExpressionToMeshWeights(entry.expression, weight: weight)
            for bind in entry.expression.materialColorBinds {
                let base = baseMaterialColors[bind.material]?[bind.type] ?? SIMD4<Float>(1, 1, 1, 1)
                colorDeltas[bind.material, default: [:]][bind.type, default: .zero] += (bind.targetValue - base) * weight
            }
            for bind in entry.expression.textureTransformBinds {
                let base = baseTextureTransforms[bind.material] ?? VRMTextureTransform()
                scaleDeltas[bind.material, default: .zero] += ((bind.scale ?? base.scale) - base.scale) * weight
                offsetDeltas[bind.material, default: .zero] += ((bind.offset ?? base.offset) - base.offset) * weight
            }
        }
        materialColorOverrides.removeAll()
        for (material, deltas) in colorDeltas {
            for (type, delta) in deltas {
                let base = baseMaterialColors[material]?[type] ?? SIMD4<Float>(1, 1, 1, 1)
                materialColorOverrides[material, default: [:]][type] = base + delta
            }
        }
        textureTransformOverrides.removeAll()
        for material in Set(scaleDeltas.keys).union(offsetDeltas.keys) {
            var transform = baseTextureTransforms[material] ?? VRMTextureTransform()
            transform.scale += scaleDeltas[material] ?? .zero
            transform.offset += offsetDeltas[material] ?? .zero
            textureTransformOverrides[material] = transform
        }
    }

    private func applyExpressionToMeshWeights(_ expression: VRMExpression, weight: Float) {
        for bind in expression.morphTargetBinds {
            var arr = meshMorphWeights[bind.node] ?? []
            if arr.count <= bind.index {
                arr.append(contentsOf: repeatElement(0.0, count: bind.index + 1 - arr.count))
            }
            arr[bind.index] += bind.weight * weight
            meshMorphWeights[bind.node] = arr
        }
    }

    private func animateExpression(
        _ preset: VRMExpressionPreset,
        to targetWeight: Float,
        duration: Float,
        completion: (@Sendable () -> Void)? = nil
    ) {
        animationTimer?.invalidate()
        let startWeight = currentWeights[preset] ?? 0
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] timer in
            let elapsed = Float(CACurrentMediaTime() - startTime)
            let progress = min(elapsed / duration, 1.0)
            let weight = lerp(startWeight, targetWeight, progress)

            Task { @MainActor [weak self] in
                self?.setExpressionWeight(preset, weight: weight)
                if progress >= 1.0 { completion?() }
            }

            if progress >= 1.0 {
                timer.invalidate()
                self?.animationTimer = nil
            }
        }
    }
}

// MARK: - Helpers

private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    Swift.max(min, Swift.min(max, value))
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}
