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
    /// Character whose bank is searched alongside the shared bank; nil =
    /// the active character (see `MemoryBanks`).
    var bank: String?
}

/// Bank policy (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C4): facts about the user
/// are shared (""), while what a character did, believes or said lives in
/// that character's bank.
enum MemoryBanks {
    static let shared = ""

    static func activeCharacter() -> String {
        RealtimeChatState.shared.selectedCharacterName.lowercased()
    }

    /// Bank for a new unit of `factType` produced while `character` is active.
    static func bank(for factType: MemoryFactType, source: String, character: String) -> String {
        switch factType {
        case .world: return shared
        case .raw: return source == "ai" ? character : shared
        case .experience, .observation: return character
        }
    }

    /// Banks recall may read for `character`; nil = every bank.
    static func readable(for character: String?, settings: MemorySettings = .shared) -> Set<String>? {
        guard !settings.charactersShareMemories else { return nil }
        return [shared, (character ?? activeCharacter()).lowercased()]
    }
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
    /// Rank-space weight of the temporal arm when the query names a time
    /// (Hindsight's per-strategy recall boost). An explicit "last weekend"
    /// is stronger evidence than a loose semantic neighbour.
    static let temporalArmWeight = 2.0

    private let store: MemoryStore
    private let embedder: EmbeddingService
    private let settings: MemorySettings

    #if DEBUG
    /// Last run's internals, for the evaluation harness and tests.
    struct Diagnostics {
        var candidateCount = 0
        var window: MemoryTimeWindow?
        var inWindowIDs: [Int64] = []
        var arms: [MemoryRecallArm: [Int64]] = [:]
        var similarity: [Int64: Double] = [:]
    }
    private(set) var lastDiagnostics = Diagnostics()
    #endif

    init(store: MemoryStore = .shared, embedder: EmbeddingService = .shared, settings: MemorySettings = .shared) {
        self.store = store
        self.embedder = embedder
        self.settings = settings
    }

    // MARK: - Entry

    func recall(_ query: MemoryRecallQuery) -> [MemoryRecallHit] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let candidates = store.fetchUnits(factTypes: query.factTypes, banks: MemoryBanks.readable(for: query.bank))
        guard !candidates.isEmpty else { return [] }
        let queryVector = embedder.generateVector(for: trimmed, purpose: .query) ?? []
        return recall(query, candidates: candidates, queryVector: queryVector, vectorModel: embedder.activeModelID)
    }

    /// Pure core, exposed for tests: runs the arms over an explicit pool.
    /// Only candidates embedded by `vectorModel` take part in the semantic
    /// arm (nil = any model with a matching dimension).
    func recall(
        _ query: MemoryRecallQuery, candidates: [MemoryUnit], queryVector: [Double], vectorModel: String? = nil
    ) -> [MemoryRecallHit] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let similarity = similarities(queryVector: queryVector, candidates: candidates, vectorModel: vectorModel)
        let window = MemoryTemporalParser.window(in: query.text, now: query.now)

        var arms: [MemoryRecallArm: [Int64]] = [:]
        arms[.semantic] = semanticArm(similarity: similarity)
        arms[.keyword] = keywordArm(query: query.text, candidates: candidates)
        arms[.graph] = graphArm(seeds: Array((arms[.semantic] ?? []).prefix(Self.graphSeedLimit)), byID: byID)
        if let window {
            arms[.temporal] = temporalArm(window: window, candidates: candidates, similarity: similarity)
        }

        #if DEBUG
        lastDiagnostics = Diagnostics(
            candidateCount: candidates.count, window: window,
            inWindowIDs: window.map { w in candidates.filter { Self.overlaps($0, w) }.map(\.id) } ?? [],
            arms: arms, similarity: similarity)
        #endif

        let fused = Self.fuse(arms, weights: window == nil ? [:] : [.temporal: Self.temporalArmWeight])
        guard !fused.isEmpty else { return [] }

        let reranked = rerank(fused, byID: byID, arms: arms, window: window, now: query.now)
        let deduped = query.preferObservations ? Self.preferObservations(reranked) : reranked
        return Self.selectWithinBudget(deduped, maxResults: query.maxResults, tokenBudget: query.tokenBudget)
    }

    // MARK: - Arms

    private func similarities(queryVector: [Double], candidates: [MemoryUnit], vectorModel: String?) -> [Int64: Double] {
        guard !queryVector.isEmpty else { return [:] }
        var result: [Int64: Double] = [:]
        for unit in candidates
        where unit.vector.count == queryVector.count && (vectorModel == nil || unit.vectorModel == vectorModel) {
            result[unit.id] = EmbeddingService.cosineSimilarity(queryVector, unit.vector)
        }
        return result
    }

    private func semanticArm(similarity: [Int64: Double]) -> [Int64] {
        let floor = embedder.calibration.queryFloor(nominal: settings.similarityFloor)
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

    /// Units inside the query's time window, ranked by how specifically
    /// their own span fits the window (a two-day event inside a weekend
    /// window beats a whole-year fact that overlaps every window), then by
    /// similarity, then recency; finally spread across time buckets so entry
    /// points cover the whole window. No similarity floor: an explicit time
    /// reference must surface what happened then even when the embedding
    /// is weak — sentence embeddings rate "what did I do last weekend?"
    /// against a hike lower than against "signed up for a marathon".
    private func temporalArm(window: MemoryTimeWindow, candidates: [MemoryUnit], similarity: [Int64: Double]) -> [Int64] {
        let inWindow = candidates.filter { Self.overlaps($0, window) }
        guard !inWindow.isEmpty else { return [] }
        let windowSpan = max(1, window.end.timeIntervalSince(window.start))
        func specificity(_ unit: MemoryUnit) -> Double {
            guard let start = unit.occurredStart else { return 1 }
            let span = max(1, (unit.occurredEnd ?? start).timeIntervalSince(start))
            return min(1, windowSpan / span)
        }
        let ranked = inWindow.sorted {
            let sa = specificity($0), sb = specificity($1)
            if abs(sa - sb) > 0.01 { return sa > sb }
            let a = similarity[$0.id] ?? 0, b = similarity[$1.id] ?? 0
            return a == b ? $0.mentionedAt > $1.mentionedAt : a > b
        }
        return Self.spreadAcrossBuckets(ranked, window: window, buckets: 5).prefix(Self.armLimit).map(\.id)
    }

    static func overlaps(_ unit: MemoryUnit, _ window: MemoryTimeWindow) -> Bool {
        if let start = unit.occurredStart {
            let end = unit.occurredEnd ?? start
            return start <= window.end && end >= window.start
        }
        return window.contains(unit.mentionedAt)
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

    /// Reciprocal rank fusion: `score(d) = Σ w_i / (k + rank_i)`. Best first.
    /// `weights` defaults every arm to 1.
    static func fuse(
        _ arms: [MemoryRecallArm: [Int64]], weights: [MemoryRecallArm: Double] = [:], k: Double = rrfK
    ) -> [(id: Int64, score: Double)] {
        var scores: [Int64: Double] = [:]
        for (arm, ranking) in arms {
            let weight = weights[arm] ?? 1
            for (rank, id) in ranking.enumerated() {
                scores[id, default: 0] += weight / (k + Double(rank + 1))
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
            if PhotoMemoryService.isPhoto(unit) { prefix += "(photo) " }
            return "- \(prefix)\(unit.text)"
        }
    }
}
