//
//  GeneratedMotionBench.swift
//  NeuraLinkTests
//
//  Developer bench, not an assertion suite: times the ARDY-mini graphs
//  through motion_bridge on whatever this process runs on (the simulator, or
//  a phone when the test is run there) — session creation, the text encoder,
//  a first window and a continuation window at 10 and 4 DDIM steps, the
//  decoder — on each execution provider the ONNX Runtime build accepts, and
//  checks the first window against the Python driver's two-window fixture.
//
//  NL_MOTION_BENCH_DIR: output folder (unset = skip).
//  NL_MOTION_MODEL_DIR: folder with model.json + the three .onnx files
//    (simulator). On a device set NL_MOTION_MODEL_DOWNLOAD=1 instead: the
//    fp32 files are fetched into Caches once and verified against model.json.
//  NL_MOTION_PROVIDERS: comma-separated subset of coreml,xnnpack,cpu.
//  NL_MOTION_STEPS: comma-separated step counts (default 10,4).
//
//  Created by Dedicatus on 29/10/2026.
//

import Compression
import CryptoKit
import Foundation
import Testing

@testable import NeuraLink

private final class FixtureMarker {}

@Suite("Generated motion bench", .serialized)
struct GeneratedMotionBench {

    private static let fixtureName = "ardy_mini_wave_windows"

    @Test("Times the motion graphs when NL_MOTION_BENCH_DIR is set")
    func bench() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_MOTION_BENCH_DIR"], !out.isEmpty else { return }
        let outputDir = Self.outputDirectory(out)
        let modelDir = try await MotionBenchModelFiles.resolve(env: env)
        let fixture = try Self.loadFixture()
        let providers = (env["NL_MOTION_PROVIDERS"] ?? "coreml,xnnpack,cpu").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { label in ARDYMotionProvider.allCases.first { $0.label == label } }
        let stepCounts = (env["NL_MOTION_STEPS"] ?? "10,4").split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }

        var report =
            "device: \(MotionBenchProbe.deviceModel)  ORT \(ARDYMotionRuntime.runtimeVersion)  model: \(modelDir.lastPathComponent)  "
        report +=
            "thermal: \(MotionBenchProbe.thermal)  footprint at start: \(MotionBenchProbe.footprintMB) MB\n"
        var seen: Set<Int32> = []
        for requested in providers {
            let created = Date()
            let runtime: ARDYMotionRuntime
            do {
                runtime = try ARDYMotionRuntime(modelDirectory: modelDir, provider: requested)
            } catch {
                report += "\n== \(requested.label): sessions failed (\(error))\n"
                continue
            }
            guard seen.insert(runtime.provider.rawValue).inserted else {
                report +=
                    "\n== \(requested.label): fell back to \(runtime.provider.label), already measured\n"
                continue
            }
            report +=
                "\n== requested \(requested.label), using \(runtime.provider.label)\(Self.registrationNote(runtime)): sessions in \(Self.ms(-created.timeIntervalSinceNow * 1000))"
            report += ", footprint \(MotionBenchProbe.footprintMB) MB\n"
            report += try Self.measure(runtime, fixture: fixture, stepCounts: stepCounts)
            report +=
                "footprint after: \(MotionBenchProbe.footprintMB) MB, thermal: \(MotionBenchProbe.thermal)\n"
        }
        try report.write(
            to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    // MARK: - Measurements

    private static func measure(
        _ runtime: ARDYMotionRuntime, fixture: MotionBenchFixture, stepCounts: [Int]
    ) throws -> String {
        var report = ""
        // Text encoder, three times (the first run warms the session).
        var encoderMs: [Double] = []
        var conditions: [Float] = []
        for _ in 0..<3 {
            let encoded = try runtime.encodeText(
                ids: fixture.tokens.ids, attentionMask: fixture.tokens.mask,
                tokenTypeIds: fixture.tokens.types)
            encoderMs.append(encoded.milliseconds)
            conditions = encoded.conditions
        }
        let conditionError = zip(conditions, fixture.textConditions).map { abs($0 - $1) }.max() ?? 0
        report +=
            "encoder: \(encoderMs.map(ms).joined(separator: " / "))  max |Δ| vs fixture \(String(format: "%.4g", conditionError))\n"

        // First window from the fixture's noise, full schedule: parity + time.
        var window = fixture.noise
        let firstSteps = try runtime.denoise(
            window: &window, historyTokens: 0, conditions: fixture.textConditions)
        let denoiseError = zip(window, fixture.denoised).map { abs($0 - $1) }.max() ?? 0
        report +=
            "first window, \(firstSteps.count) steps: \(ms(firstSteps.reduce(0, +))) total, steps \(firstSteps.map(ms).joined(separator: " "))"
        report += "  max |Δ| vs fixture \(String(format: "%.4g", denoiseError))\n"
        if runtime.provider == .cpu {
            #expect(
                denoiseError < 0.01, "CPU provider drifts from the Python driver by \(denoiseError)"
            )
        }

        // The decoder on the fixture's recentered input: parity + time.
        let translation = SIMD3<Float>(
            fixture.globalTranslation[0], fixture.globalTranslation[1], fixture.globalTranslation[2]
        )
        var decoded = try runtime.decode(
            hybrid: fixture.decoderInput, validTokens: 10, globalTranslation: translation)
        decoded = try runtime.decode(
            hybrid: fixture.decoderInput, validTokens: 10, globalTranslation: translation)
        let frame0 = Array(decoded.localRotations.prefix(ARDYDecodedWindow.joints * 9))
        let rotationError =
            zip(frame0, fixture.localRotationsFrame0).map { abs($0 - $1) }.max() ?? 0
        let rootError =
            zip(decoded.rootPositions.prefix(120), fixture.rootPositions).map { abs($0 - $1) }.max()
            ?? 0
        report +=
            "decoder: \(ms(decoded.milliseconds))  max |Δ| local rotations \(String(format: "%.4g", rotationError)), root \(String(format: "%.4g", rootError))\n"

        // A continuation window (10 history tokens) at each step count — the
        // steady-state cost per 2 s of motion.
        for steps in stepCounts {
            var continuation = [Float](repeating: 0, count: ARDYMotionRuntime.windowFloats)
            let historyFloats = 10 * ARDYMotionRuntime.hybridDimension
            continuation.replaceSubrange(0..<historyFloats, with: window.prefix(historyFloats))
            continuation.replaceSubrange(
                historyFloats..<(2 * historyFloats), with: fixture.noise.prefix(historyFloats))
            let stepMs = try runtime.denoise(
                window: &continuation, historyTokens: 10, conditions: fixture.textConditions,
                steps: steps)
            report +=
                "continuation window, \(stepMs.count) steps: \(ms(stepMs.reduce(0, +))) total, mean step \(ms(stepMs.reduce(0, +) / Double(stepMs.count)))\n"
        }
        return report
    }

    private static func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }

    /// How CoreML was registered, when it is the provider in use.
    private static func registrationNote(_ runtime: ARDYMotionRuntime) -> String {
        runtime.provider == .coreML ? " (\(runtime.coreMLRegistration))" : ""
    }

    /// The folder named by NL_MOTION_BENCH_DIR when this process can create
    /// it (the simulator); otherwise the app's Documents folder (a phone),
    /// where Xcode's container download or Finder's file sharing finds it.
    private static func outputDirectory(_ requested: String) -> URL {
        let wanted = URL(fileURLWithPath: requested, isDirectory: true)
        let created = (try? FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true)) != nil
        if created, FileManager.default.isWritableFile(atPath: wanted.path) {
            return wanted
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("motion-bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    // MARK: - Fixture

    private static func loadFixture() throws -> MotionBenchFixture {
        let bundled = Bundle(for: FixtureMarker.self).url(
            forResource: Self.fixtureName, withExtension: "json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(Self.fixtureName).json")
        let url = try #require(
            bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil))
        return try JSONDecoder().decode(MotionBenchFixture.self, from: Data(contentsOf: url))
    }
}

// MARK: - Fixture shape (scripts/ardy_mini_batch.py, first window of "A person waves" seed 1)

private struct MotionBenchTokens: Decodable {
    let ids: [Int64]
    let mask: [Int64]
    let types: [Int64]
}

/// The first window of scripts/ardy_mini_batch.py's two-window fixture
/// (NeuraLinkTests/Fixtures/ardy_mini_wave_windows.json).
private struct MotionBenchWindow: Decodable {
    let noise: [Float]
    let denoised: [Float]
    let decoderInput: [Float]
    let globalTranslation: [Float]
    let localRotationsFrame0: [Float]
    let rootPositions: [Float]

    enum CodingKeys: String, CodingKey {
        case noise, denoised
        case decoderInput = "decoder_input"
        case globalTranslation = "global_translation"
        case localRotationsFrame0 = "local_rotations_frame0"
        case rootPositions = "root_positions"
    }
}

private struct MotionBenchFixture: Decodable {
    let caption: String
    let tokens: MotionBenchTokens
    let textConditions: [Float]
    let windows: [MotionBenchWindow]

    enum CodingKeys: String, CodingKey {
        case caption, tokens, windows
        case textConditions = "text_conditions"
    }

    var noise: [Float] { windows[0].noise }
    var denoised: [Float] { windows[0].denoised }
    var decoderInput: [Float] { windows[0].decoderInput }
    var globalTranslation: [Float] { windows[0].globalTranslation }
    var localRotationsFrame0: [Float] { windows[0].localRotationsFrame0 }
    var rootPositions: [Float] { windows[0].rootPositions }
}

// MARK: - Process probes

private enum MotionBenchProbe {
    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        let machine = String(cString: buffer)
        #if targetEnvironment(simulator)
            return "simulator (\(machine))"
        #else
            return machine
        #endif
    }

    /// Physical footprint in MB, the number Xcode's memory gauge shows.
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }
}
