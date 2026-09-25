//
//  MemoryRecall.swift
//  NeuraLink
//
//  Hybrid recall — the on-device port of Hindsight's TEMPR retrieval
//  (docs/AGENTIC_MEMORY.md §Recall). No LLM call. Four arms run over the
//  candidate pool (semantic, keyword/BM25, entity-graph link expansion,
//  temporal), their rankings are fused with reciprocal rank fusion, and the
//  fused list is reranked with recency / temporal-proximity / evidence
//  boosts before a token-budgeted selection.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

enum MemoryRecallArm: String, CaseIterable, Sendable {
    case semantic, keyword, graph, temporal
}

struct MemoryRecallQuery {
    var text: String
    var factTypes: Set<MemoryFactType> = MemoryFactType.knowledge
    var maxResults: Int = 5
    /// Approximate prompt-token budget for the returned units.
    var tokenBudget: Int = 400
    /// Drop facts already covered by a returned observation.
    var preferObservations: Bool = true
    var now: Date = Date()
}

struct MemoryRecallHit: Identifiable {
    let unit: MemoryUnit
    let score: Double
    let arms: Set<MemoryRecallArm>
    var id: Int64 { unit.id }
}

final class MemoryRecall {

    static let shared = MemoryRecall()

    /// Reciprocal-rank-fusion constant (Hindsight default).
    static let rrfK = 60.0
    /// Semantic seeds that feed link expansion.
    static let graphSeedLimit = 20
    /// Per-arm cap before fusion.
    static let armLimit = 50
    /// Minimum similarity for a unit to count inside a temporal window.
    static let temporalSimilarityFloor = 0.1

    private let store: MemoryStore
    private let embedder: EmbeddingService
    private let settings: MemorySettings

    init(store: MemoryStore = .shared, embedder: EmbeddingService = .shared, settings: MemorySettings = .shared) {
        self.store = store
        self.embedder = embedder
        self.settings = settings
    }

    // MARK: - Entry

    func recall(_ query: MemoryRecallQuery) -> [MemoryRecallHit] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let candidates = store.fetchUnits(factTypes: query.factTypes)
        guard !candidates.isEmpty else { return [] }
        let queryVector = embedder.generateVector(for: trimmed) ?? []
        return recall(query, candidates: candidates, queryVector: queryVector)
    }

    /// Pure core, exposed for tests: runs the arms over an explicit pool.
    func recall(_ query: MemoryRecallQuery, candidates: [MemoryUnit], queryVector: [Double]) -> [MemoryRecallHit] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let similarity = similarities(queryVector: queryVector, candidates: candidates)
        let window = MemoryTemporalParser.window(in: query.text, now: query.now)

        var arms: [MemoryRecallArm: [Int64]] = [:]
        arms[.semantic] = semanticArm(similarity: similarity)
        arms[.keyword] = keywordArm(query: query.text, candidates: candidates)
        arms[.graph] = graphArm(seeds: Array((arms[.semantic] ?? []).prefix(Self.graphSeedLimit)), byID: byID)
        if let window {
            arms[.temporal] = temporalArm(window: window, candidates: candidates, similarity: similarity)
        }

        let fused = Self.fuse(arms)
        guard !fused.isEmpty else { return [] }

        let reranked = rerank(fused, byID: byID, arms: arms, window: window, now: query.now)
        let deduped = query.preferObservations ? Self.preferObservations(reranked) : reranked
        return Self.selectWithinBudget(deduped, maxResults: query.maxResults, tokenBudget: query.tokenBudget)
    }

    // MARK: - Arms

    private func similarities(queryVector: [Double], candidates: [MemoryUnit]) -> [Int64: Double] {
        guard !queryVector.isEmpty else { return [:] }
        var result: [Int64: Double] = [:]
        for unit in candidates where unit.vector.count == queryVector.count {
            result[unit.id] = EmbeddingService.cosineSimilarity(queryVector, unit.vector)
        }
        return result
    }

    private func semanticArm(similarity: [Int64: Double]) -> [Int64] {
        let floor = settings.similarityFloor
        return similarity
            .filter { $0.value > floor }
            .sorted { $0.value > $1.value }
            .prefix(Self.armLimit)
            .map(\.key)
    }

    private func keywordArm(query: String, candidates: [MemoryUnit]) -> [Int64] {
        let documents = candidates.map { MemoryTextIndex.Document(id: $0.id, tokens: $0.tokens) }
        return MemoryTextIndex.bm25(query: query, documents: documents)
            .prefix(Self.armLimit)
            .map(\.0)
    }

    /// One-hop link expansion from the semantic seeds. Three additive
    /// signals per neighbour: entity overlap `tanh(shared × 0.5)`, semantic
    /// link weight, causal link weight + 1.0.
    private func graphArm(seeds: [Int64], byID: [Int64: MemoryUnit]) -> [Int64] {
        guard !seeds.isEmpty else { return [] }
        let seedSet = Set(seeds)
        var scores: [Int64: Double] = [:]

        for link in store.fetchLinks(touching: seeds) {
            let neighbour = seedSet.contains(link.fromID) ? link.toID : link.fromID
            guard !seedSet.contains(neighbour), byID[neighbour] != nil else { continue }
            switch link.kind {
            case .semantic, .entity, .temporal: scores[neighbour, default: 0] += link.weight
            case .causedBy: scores[neighbour, default: 0] += link.weight + 1.0
            }
        }

        let seedEntities = Array(Set(seeds.flatMap { byID[$0]?.entities ?? [] }))
        for (unitID, shared) in store.unitsSharingEntities(names: seedEntities, excluding: seedSet)
        where byID[unitID] != nil {
            scores[unitID, default: 0] += tanh(Double(shared) * 0.5)
        }

        return scores.sorted { $0.value > $1.value }.prefix(Self.armLimit).map(\.key)
    }

    /// Units inside the query's time window, ranked by similarity and then
    /// spread across time buckets so entry points cover the whole window.
    private func temporalArm(window: MemoryTimeWindow, candidates: [MemoryUnit], similarity: [Int64: Double]) -> [Int64] {
        let inWindow = candidates.filter { unit in
            if let start = unit.occurredStart {
                let end = unit.occurredEnd ?? start
                return start <= window.end && end >= window.start
            }
            return window.contains(unit.mentionedAt)
        }
        guard !inWindow.isEmpty else { return [] }
        let hasVectors = !similarity.isEmpty
        let ranked = inWindow
            .filter { !hasVectors || (similarity[$0.id] ?? 0) >= Self.temporalSimilarityFloor }
            .sorted {
                let a = similarity[$0.id] ?? 0, b = similarity[$1.id] ?? 0
                return a == b ? $0.mentionedAt > $1.mentionedAt : a > b
            }
        return Self.spreadAcrossBuckets(ranked, window: window, buckets: 5).prefix(Self.armLimit).map(\.id)
    }

    static func spreadAcrossBuckets(_ ranked: [MemoryUnit], window: MemoryTimeWindow, buckets: Int) -> [MemoryUnit] {
        let span = max(1, window.end.timeIntervalSince(window.start))
        var byBucket: [[MemoryUnit]] = Array(repeating: [], count: buckets)
        for unit in ranked {
            let offset = unit.recencyDate.timeIntervalSince(window.start) / span
            let index = min(buckets - 1, max(0, Int(offset * Double(buckets))))
            byBucket[index].append(unit)
        }
        var out: [MemoryUnit] = []
        var round = 0
        while out.count < ranked.count {
            for bucket in byBucket where round < bucket.count { out.append(bucket[round]) }
            round += 1
        }
        return out
    }

    // MARK: - Fusion

    /// Reciprocal rank fusion: `score(d) = Σ 1 / (k + rank_i)`. Best first.
    static func fuse(_ arms: [MemoryRecallArm: [Int64]], k: Double = rrfK) -> [(id: Int64, score: Double)] {
        var scores: [Int64: Double] = [:]
        for (_, ranking) in arms {
            for (rank, id) in ranking.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(rank + 1))
            }
        }
        return scores.map { (id: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
    }

    // MARK: - Rerank

    /// No cross-encoder on device: the base score is seeded from the fused
    /// rank (Hindsight's passthrough-reranker path), then multiplied by the
    /// recency, temporal-proximity, evidence and pin boosts.
    private func rerank(
        _ fused: [(id: Int64, score: Double)],
        byID: [Int64: MemoryUnit],
        arms: [MemoryRecallArm: [Int64]],
        window: MemoryTimeWindow?,
        now: Date
    ) -> [MemoryRecallHit] {
        let halfLife = max(0.1, settings.recencyHalfLifeDays)
        let recencyWeight = min(max(settings.recencyWeight, 0), 1)
        var hits: [MemoryRecallHit] = []
        for (rank, entry) in fused.enumerated() {
            guard let unit = byID[entry.id] else { continue }
            let base = 1 / Double(rank + 1)
            let ageDays = max(0, now.timeIntervalSince(unit.recencyDate) / 86_400)
            let recency = exp(-ageDays / halfLife)
            let temporal = window?.proximity(of: unit.recencyDate) ?? 0.5
            let proof = unit.factType == .observation
                ? min(1, log(1 + Double(unit.proofCount)) / log(11)) : 0.5
            let score = base
                * (1 + 0.8 * recencyWeight * (recency - 0.5))
                * (1 + 0.2 * (temporal - 0.5))
                * (1 + 0.1 * (proof - 0.5))
                * (unit.pinned ? 1.15 : 1.0)
            let armSet = Set(arms.filter { $0.value.contains(unit.id) }.map(\.key))
            hits.append(MemoryRecallHit(unit: unit, score: score, arms: armSet))
        }
        return hits.sorted { $0.score > $1.score }
    }

    /// Drops facts whose id appears in the sources of a returned observation.
    static func preferObservations(_ hits: [MemoryRecallHit]) -> [MemoryRecallHit] {
        let covered = Set(hits.filter { $0.unit.factType == .observation }.flatMap(\.unit.sourceIDs))
        guard !covered.isEmpty else { return hits }
        return hits.filter { $0.unit.factType == .observation || !covered.contains($0.unit.id) }
    }

    /// Top-down selection until the token budget is exhausted; a unit that
    /// does not fit is skipped rather than truncated.
    static func selectWithinBudget(_ hits: [MemoryRecallHit], maxResults: Int, tokenBudget: Int) -> [MemoryRecallHit] {
        var remaining = tokenBudget
        var out: [MemoryRecallHit] = []
        for hit in hits where out.count < maxResults {
            let cost = hit.unit.estimatedTokens
            guard cost <= remaining else { continue }
            remaining -= cost
            out.append(hit)
        }
        return out
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// One bullet per hit. Event facts carry their date; observations carry
    /// their evidence count so the model can weigh them.
    static func bulletLines(_ hits: [MemoryRecallHit]) -> [String] {
        hits.map { hit in
            let unit = hit.unit
            var prefix = ""
            if let start = unit.occurredStart {
                prefix = "(\(dateFormatter.string(from: start))) "
            } else if unit.factType == .raw {
                prefix = "(\(dateFormatter.string(from: unit.mentionedAt))) "
            }
            if unit.factType == .observation, unit.proofCount > 1 {
                prefix += "[×\(unit.proofCount)] "
            }
            return "- \(prefix)\(unit.text)"
        }
    }
}
