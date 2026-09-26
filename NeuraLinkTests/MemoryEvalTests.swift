//
//  MemoryEvalTests.swift
//  NeuraLinkTests
//
//  Runs the memory evaluation harness against the shared store and fails when recall regresses below the
//  ratcheted thresholds. Apple's English NLEmbedding is available on the
//  simulator, so all four arms are measured; the on-device run
//  (`-nl.debug.memoryEval YES`) confirms the numbers with device assets.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Memory evaluation harness", .serialized)
struct MemoryEvalTests {

    /// Baselines (fixture v1, 2026-09-26). With Apple's English sentence
    /// embedding available (a developer simulator that has the asset):
    /// recall@5 1.00, MRR 0.82, avoid 0.88 — the floor allows one miss.
    /// Without it (a freshly erased simulator, as on CI, where `NLEmbedding`
    /// returns zero vectors and only the keyword, graph and temporal arms
    /// run): 22/24 = 0.917, the two pure-semantic questions miss — the floor
    /// allows those two and nothing else.
    static let overallRecallFloorWithEmbeddings = 0.93
    static let overallRecallFloorWithoutEmbeddings = 0.90
    static let perTypeRecallFloor = 0.70
    static let avoidPrecisionFloor = 0.80

    /// True when the active embedding backend produces non-zero vectors.
    static var semanticArmAvailable: Bool {
        EmbeddingService.shared.generateVector(for: "calibration probe", purpose: .query)?.contains { $0 != 0 } == true
    }

    static var overallRecallFloor: Double {
        semanticArmAvailable ? overallRecallFloorWithEmbeddings : overallRecallFloorWithoutEmbeddings
    }

    @Test("Fixture parses and covers every question type")
    func fixtureShape() throws {
        let cases = try MemoryEvalRunner.parseCases(MemoryEvalFixture.json)
        #expect(cases.count >= 20)
        let types = Set(cases.flatMap(\.questions).map(\.type))
        for expected in ["single_hop", "multi_session", "temporal", "knowledge_update", "preference"] {
            #expect(types.contains(expected), "missing question type \(expected)")
        }
        #expect(Set(cases.map(\.id)).count == cases.count, "duplicate case ids")
    }

    @Test("Recall quality stays above the ratcheted thresholds")
    func recallQuality() async throws {
        let report = try await MemoryEvalRunner().run()
        let overall = report.overall
        let mode = Self.semanticArmAvailable ? "with embeddings" : "WITHOUT embeddings (zero vectors)"
        let detail = (["[MemoryEval] mode: \(mode), floor \(Self.overallRecallFloor)"] + report.summaryLines
            + report.failures.map { "miss: \($0)" }).joined(separator: "\n")
        // Readable from the xcresult on every run, pass or fail:
        //   xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>
        Attachment.record(Data(detail.utf8), named: "memory_eval_\(MemoryEvalFixture.version).txt")
        #expect(overall.questions >= 20)
        #expect(overall.recallAtK >= Self.overallRecallFloor,
                "overall recall@5 \(overall.recallAtK) below \(Self.overallRecallFloor)\n\(detail)")
        #expect(overall.avoidPrecision >= Self.avoidPrecisionFloor,
                "avoid precision \(overall.avoidPrecision) below \(Self.avoidPrecisionFloor)")
        for (type, score) in report.perType {
            #expect(score.recallAtK >= Self.perTypeRecallFloor,
                    "\(type) recall@5 \(score.recallAtK) below \(Self.perTypeRecallFloor)\n\(detail)")
        }
        // Nothing the harness inserted may survive the run.
        #expect(MemoryStore.shared.fetchUnits(factTypes: [.world]).allSatisfy { !$0.text.contains("Tre Cime") })
    }

    /// Calibration run with the GGUF embedding model. Skipped unless the test
    /// environment provides a model path:
    ///   env TEST_RUNNER_NL_EMBED_GGUF=/path/embeddinggemma-300M-Q8_0.gguf xcodebuild test …
    @Test("Recall quality with the multilingual GGUF embedding model (opt-in)")
    func recallQualityGGUF() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_EMBED_GGUF"],
              FileManager.default.fileExists(atPath: path)
        else { return }
        EmbeddingService.shared.useGGUFModel(at: path)
        defer { EmbeddingService.shared.useGGUFModel(at: nil) }
        #expect(EmbeddingService.shared.activeModelID == GGUFEmbeddingBackend.backendID)
        let probe = EmbeddingService.shared.generateVector(for: "calibration probe", purpose: .query)
        #expect(probe?.count == 768)

        let report = try await MemoryEvalRunner().run()
        let detail = (report.summaryLines + report.failures.map { "miss: \($0)" }).joined(separator: "\n")
        Attachment.record(Data(detail.utf8), named: "memory_eval_\(MemoryEvalFixture.version)_gguf.txt")
        #expect(report.overall.recallAtK >= Self.overallRecallFloor, "gguf recall@5 \(report.overall.recallAtK)\n\(detail)")
    }
}
