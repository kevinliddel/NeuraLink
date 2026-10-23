//
//  SpringBoneRingingDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: measures how a model's spring chains react to a breathing
//  bob — swing amplitude, oscillation rate and settle time per chain — so a
//  "pulsating hair" report can be judged on numbers before and after a
//  physics change. Set NL_SPRING_DIAG_DIR to run; NL_SPRING_DIAG_MODELS adds
//  colon-separated .vrm paths beside the bundled characters.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Metal
import Testing
import simd
@testable import NeuraLink

@Suite("Spring bone ringing diagnostic", .serialized)
struct SpringBoneRingingDiagnostic {

    private struct ChainReport {
        let root: String
        let joints: Int
        let stiffness: Float
        let drag: Float
        let restJitter: Float     // m per frame while nothing moves
        let restJitterNoColliders: Float  // same, with every collider switched off
        let tipPenetration: Float // m the tip sits inside the nearest collider in the bind pose
        let swingAmplitude: Float // m, tip relative to root during the bob
        let reversalsPerSecond: Float
        let settleSeconds: Float  // after the bob stops, until swing < 10% of peak
    }

    @Test("Measure chain ringing when NL_SPRING_DIAG_DIR is set")
    @MainActor
    func measure() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_SPRING_DIAG_DIR"], !path.isEmpty else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var models: [(String, URL)] = []
        for name in ["Ekaterina", "Oz", "Sonya"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "vrm") { models.append((name, url)) }
        }
        let extra = ProcessInfo.processInfo.environment["NL_SPRING_DIAG_MODELS"] ?? ""
        for p in extra.split(separator: ":") where !p.isEmpty {
            let url = URL(fileURLWithPath: String(p))
            models.append((url.deletingPathExtension().lastPathComponent, url))
        }

        var report = "model\tchain\tjoints\tstiff\tdrag\trestJitter_mm\tnoColliders_mm\tpenetration_mm\tswing_mm\treversals_per_s\tsettle_s\n"
        var summary = ""
        for (name, url) in models {
            let model = try await VRMModel.load(from: url, device: device)
            guard model.springBone != nil else { continue }
            let solver = SpringBoneSolver()
            solver.setUp(model: model)
            solver.warmUp(steps: 120)
            let chains = Self.measureChains(model: model, solver: solver)
            for c in chains {
                report += "\(name)\t\(c.root)\t\(c.joints)\t\(c.stiffness)\t\(c.drag)\t"
                    + String(
                        format: "%.3f\t%.3f\t%.1f\t%.1f\t%.2f\t%.2f\n", c.restJitter * 1000, c.restJitterNoColliders * 1000,
                        c.tipPenetration * 1000, c.swingAmplitude * 1000, c.reversalsPerSecond, c.settleSeconds)
            }
            let hair = chains.filter { $0.root.lowercased().contains("hair") }
            let skirt = chains.filter { $0.root.lowercased().contains("skirt") }
            func line(_ label: String, _ set: [ChainReport]) -> String {
                guard !set.isEmpty else { return "" }
                let swing = set.map(\.swingAmplitude).sorted()
                let settle = set.map(\.settleSeconds).sorted()
                let rev = set.map(\.reversalsPerSecond).sorted()
                return String(
                    format: "  %@ n=%d swing med/max %.1f/%.1f mm, reversals med %.1f/s, settle med/max %.2f/%.2f s\n",
                    label, set.count, swing[swing.count / 2] * 1000, swing.last! * 1000, rev[rev.count / 2],
                    settle[settle.count / 2], settle.last!)
            }
            summary += "\(name): \(chains.count) chains\n" + line("hair", hair) + line("skirt", skirt)
        }
        try report.write(to: outputDir.appendingPathComponent("spring_ringing.tsv"), atomically: true, encoding: .utf8)
        try summary.write(to: outputDir.appendingPathComponent("spring_ringing_summary.txt"), atomically: true, encoding: .utf8)
        #expect(!summary.isEmpty)
    }

    // MARK: - Measurement

    /// How far each joint (by global index) sits inside the nearest sphere
    /// or capsule collider in the current node pose, hit radius included.
    @MainActor
    private static func tipPenetrations(model: VRMModel, springBone: VRMSpringBone) -> [Int: Float] {
        var spheres: [(SIMD3<Float>, Float)] = []
        var capsules: [(SIMD3<Float>, SIMD3<Float>, Float)] = []
        for collider in springBone.colliders {
            guard let node = model.nodes[safe: collider.node] else { continue }
            let wm = node.worldMatrix
            let rot = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]), SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2]))
            switch collider.shape {
            case .sphere(let offset, let radius): spheres.append((node.worldPosition + rot * offset, radius))
            case .capsule(let offset, let radius, let tail):
                let p0 = node.worldPosition + rot * offset
                capsules.append((p0, p0 + rot * tail, radius))
            case .plane: break
            }
        }
        var result: [Int: Float] = [:]
        var index = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                defer { index += 1 }
                guard let node = model.nodes[safe: joint.node] else { continue }
                let p = node.worldPosition
                var worst: Float = 0
                for (c, r) in spheres { worst = max(worst, r + joint.hitRadius - simd_distance(p, c)) }
                for (a, b, r) in capsules {
                    let ab = b - a
                    let t = simd_length_squared(ab) > 1e-6 ? max(0, min(1, simd_dot(p - a, ab) / simd_length_squared(ab))) : 0
                    worst = max(worst, r + joint.hitRadius - simd_distance(p, a + t * ab))
                }
                result[index] = worst
            }
        }
        return result
    }

    private static let frameDT: TimeInterval = 1.0 / 60.0

    @MainActor
    private static func measureChains(model: VRMModel, solver: SpringBoneSolver) -> [ChainReport] {
        guard let springBone = model.springBone,
              let hipsIndex = model.humanoid?.getBoneNode(.hips), let hips = model.nodes[safe: hipsIndex]
        else { return [] }
        // Global joint order: springs in order, joints in order.
        var chainRanges: [(spring: VRMSpring, first: Int, last: Int)] = []
        var index = 0
        for spring in springBone.springs {
            chainRanges.append((spring, index, index + spring.joints.count - 1))
            index += spring.joints.count
        }
        let baseLocal = hips.localMatrix

        let jointNodes = springBone.springs.flatMap { $0.joints.map { model.nodes[safe: $0.node] } }
        func step(dy: Float) -> [SIMD3<Float>] {
            var local = baseLocal
            local.columns.3.y = baseLocal.columns.3.y + dy
            hips.localMatrix = local
            model.updateNodeTransforms()
            solver.update(deltaTime: Float(frameDT))
            return jointNodes.map { $0?.worldPosition ?? .zero }
        }

        // Phase A: nothing moves.
        var restFrames: [[SIMD3<Float>]] = []
        for _ in 0..<120 { restFrames.append(step(dy: 0)) }
        // Phase A2: nothing moves and nothing collides.
        let saved = model.springBone
        for index in springBone.springs.indices { model.springBone?.springs[index].colliderGroups = [] }
        solver.setUp(model: model)
        solver.warmUp(steps: 120)
        var noColliderFrames: [[SIMD3<Float>]] = []
        for _ in 0..<120 { noColliderFrames.append(step(dy: 0)) }
        model.springBone = saved
        solver.setUp(model: model)
        solver.warmUp(steps: 120)
        for _ in 0..<60 { _ = step(dy: 0) }  // settle back with colliders on
        let penetrations = Self.tipPenetrations(model: model, springBone: springBone)
        // Phase B: breathing bob, ±8 mm at 0.33 Hz for 6 s.
        var bobFrames: [[SIMD3<Float>]] = []
        for f in 0..<360 {
            let t = Float(f) * Float(frameDT)
            bobFrames.append(step(dy: 0.008 * sin(2 * .pi * 0.33 * t)))
        }
        // Phase C: hold still and let it settle.
        var settleFrames: [[SIMD3<Float>]] = []
        for _ in 0..<600 { settleFrames.append(step(dy: 0)) }

        var reports: [ChainReport] = []
        for (spring, first, last) in chainRanges where last > first {
            let rootName = model.nodes[safe: spring.joints[0].node]?.name ?? "?"
            let joint = spring.joints[1]
            func rel(_ frame: [SIMD3<Float>]) -> SIMD3<Float> { frame[last] - frame[first] }

            // Rest jitter: largest tip move between consecutive frames once settled.
            var jitter: Float = 0
            for i in 61..<restFrames.count {
                jitter = max(jitter, simd_length(rel(restFrames[i]) - rel(restFrames[i - 1])))
            }
            var jitterNoColliders: Float = 0
            for i in 61..<noColliderFrames.count {
                jitterNoColliders = max(jitterNoColliders, simd_length(rel(noColliderFrames[i]) - rel(noColliderFrames[i - 1])))
            }
            // Swing: tip-relative-to-root deviation from its mean during the bob.
            let bobRel = bobFrames.map(rel)
            let mean = bobRel.reduce(SIMD3<Float>(repeating: 0), +) / Float(bobRel.count)
            let dev = bobRel.map { $0 - mean }
            let swing = dev.map(simd_length).max() ?? 0
            // Reversals: direction changes of the deviation's velocity along
            // whichever axis swings most (x or z), i.e. twice the swing rate.
            let varX = dev.reduce(Float(0)) { $0 + $1.x * $1.x }
            let varZ = dev.reduce(Float(0)) { $0 + $1.z * $1.z }
            let axis: KeyPath<SIMD3<Float>, Float> = varX >= varZ ? \.x : \.z
            var reversals = 0
            var lastSign: Float = 0
            for i in 1..<dev.count {
                let v = dev[i][keyPath: axis] - dev[i - 1][keyPath: axis]
                let sign: Float = v > 0.00002 ? 1 : (v < -0.00002 ? -1 : 0)
                if sign != 0 && lastSign != 0 && sign != lastSign { reversals += 1 }
                if sign != 0 { lastSign = sign }
            }
            // Settle: frames after the bob until the deviation stays under 10% of the peak.
            let settleRel = settleFrames.map(rel)
            let threshold = max(swing * 0.1, 0.0005)
            var settledAt = settleFrames.count
            for i in stride(from: settleRel.count - 1, through: 0, by: -1) {
                if simd_length(settleRel[i] - mean) > threshold { settledAt = i + 1; break }
                if i == 0 { settledAt = 0 }
            }
            reports.append(ChainReport(
                root: rootName, joints: last - first + 1, stiffness: joint.stiffness, drag: joint.dragForce,
                restJitter: jitter, restJitterNoColliders: jitterNoColliders,
                tipPenetration: penetrations[last] ?? 0, swingAmplitude: swing,
                reversalsPerSecond: Float(reversals) / 6.0,
                settleSeconds: Float(settledAt) * Float(frameDT)))
        }
        return reports
    }
}
