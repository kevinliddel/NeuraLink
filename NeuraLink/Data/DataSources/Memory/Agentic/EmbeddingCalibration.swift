//
//  EmbeddingCalibration.swift
//  NeuraLink
//
//  Per-backend cosine calibration (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C2).
//  Different embedding models put "related" and "unrelated" at different
//  cosine values, so the user-facing Memory Quality slider (0.3…0.7) and
//  the internal link / dedup floors are expressed on a nominal scale and
//  mapped here. Values come from the memory evaluation harness
//  (NeuraLinkTests/MemoryEvalTests), not from intuition.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

struct EmbeddingCalibration: Sendable {
    /// Affine map from the nominal Memory Quality floor (0.3…0.7) to the
    /// semantic arm's cosine floor: `offset + scale × nominal`.
    let queryFloorOffset: Double
    let queryFloorScale: Double
    /// Cosine at/above which two units get a semantic link.
    let semanticLinkFloor: Double
    /// Cosine at/above which two observations are the same belief.
    let dedupThreshold: Double

    /// Apple NLEmbedding sentence vectors (English). Harness data
    /// (2026-09-26): question ↔ correct fact 0.21–0.22, question ↔ best
    /// unrelated fact 0.15–0.18, so a nominal floor of 0.5 × 0.4 = 0.20 keeps
    /// the answer and drops the runner-up (slider ends map to 0.12 / 0.28).
    /// Fact ↔ nearest fact: p10 0.45, p50 0.59, p90 0.66 — a link floor of
    /// 0.62 links the clearly related third, not everything.
    static let appleNL = EmbeddingCalibration(
        queryFloorOffset: 0, queryFloorScale: 0.4, semanticLinkFloor: 0.62, dedupThreshold: 0.9)

    /// EmbeddingGemma-300M Q8_0. Bridge probe (2026-09-26): question ↔
    /// matching fact 0.58, question ↔ unrelated fact 0.32, fact ↔ unrelated
    /// fact 0.45. Slider maps 0.3 → 0.28, 0.5 → 0.40, 0.7 → 0.52. Refined by
    /// the harness run (see docs/AGENTIC_MEMORY.md §Embedding calibration).
    static let embeddingGemma = EmbeddingCalibration(
        queryFloorOffset: 0.1, queryFloorScale: 0.6, semanticLinkFloor: 0.6, dedupThreshold: 0.9)

    func queryFloor(nominal: Double) -> Double {
        min(max(queryFloorOffset + nominal * queryFloorScale, 0), 1)
    }
}
