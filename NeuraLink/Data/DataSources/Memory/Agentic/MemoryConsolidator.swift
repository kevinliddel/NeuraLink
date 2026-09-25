//
//  MemoryConsolidator.swift
//  NeuraLink
//
//  Observation consolidation (docs/AGENTIC_MEMORY.md §Observations). Folds
//  freshly retained world/experience facts into deduplicated observations:
//  for each batch the existing observations are pooled via recall, one LLM
//  call returns CREATE / UPDATE / DELETE actions, and a cosine dedup guard
//  merges near-identical beliefs. Runs after retain; never on the hot path.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

final class MemoryConsolidator: @unchecked Sendable {

    static let shared = MemoryConsolidator()

    /// Facts per LLM call (Hindsight: 8; small local models get fewer).
    static func batchSize(for tier: MemoryLLMTier) -> Int { tier == .cloud ? 8 : 3 }
    /// Max batches per run so a backlog never monopolises the engine.
    static let maxBatchesPerRun = 4
    /// Cosine at/above which a batch fact counts as evidence for an observation.
    static let evidenceFloor = 0.3
    static let cloudMaxTokens = 400
    static let localMaxTokens = 120

    enum Action: Equatable {
        case create(String)
        case update(Int64, String)
        case delete(Int64)
    }

    private let store: MemoryStore
    private let embedder: EmbeddingService
    private let llm: MemoryLLM
    private let recall: MemoryRecall
    private let lock = NSLock()
    private var inFlight = false

    init(
        store: MemoryStore = .shared,
        embedder: EmbeddingService = .shared,
        llm: MemoryLLM = LiveMemoryLLM(),
        recall: MemoryRecall = .shared
    ) {
        self.store = store
        self.embedder = embedder
        self.llm = llm
        self.recall = recall
    }

    // MARK: - Entry

    /// Consolidates every pending fact in batches, then refreshes stale
    /// mental models. Safe to call repeatedly; overlapping runs are skipped.
    func consolidatePending() async {
        let tier = llm.tier
        guard tier != .none else { return }
        let acquired = lock.withLock { () -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard acquired else { return }
        defer { lock.withLock { inFlight = false } }

        var changed = false
        for _ in 0..<Self.maxBatchesPerRun {
            let batch = store.fetchUnconsolidatedUnits(limit: Self.batchSize(for: tier))
            guard !batch.isEmpty else { break }
            changed = await consolidate(batch: batch) || changed
        }
        if changed {
            store.markMentalModelsStale()
            await MemoryMentalModels.shared.refreshStale(character: RealtimeChatState.shared.selectedCharacterName)
        }
    }

    /// One batch → one LLM call → applied actions. Facts are marked
    /// consolidated even when the model returns nothing, so a bad batch
    /// cannot wedge the queue. Returns true when an observation changed.
    func consolidate(batch: [MemoryUnit]) async -> Bool {
        let existing = pooledObservations(for: batch)
        let character = RealtimeChatState.shared.selectedCharacterName
        let raw = await llm.complete(
            system: Self.systemPrompt(disposition: MemoryDisposition.forCharacter(character)),
            user: Self.userPrompt(facts: batch, observations: existing),
            maxTokens: llm.tier == .cloud ? Self.cloudMaxTokens : Self.localMaxTokens)
        let actions = Self.parse(raw ?? "")
        let changed = apply(actions, batch: batch, existing: existing)
        store.markConsolidated(ids: batch.map(\.id))
        nlLog("[MemoryConsolidator] \(batch.count) facts → \(actions.count) actions (\(llm.tier))", level: .info)
        return changed
    }

    // MARK: - Pooling

    /// Existing observations relevant to any fact in the batch.
    private func pooledObservations(for batch: [MemoryUnit]) -> [MemoryUnit] {
        var seen = Set<Int64>()
        var pooled: [MemoryUnit] = []
        for fact in batch {
            let query = MemoryRecallQuery(
                text: fact.text, factTypes: [.observation], maxResults: 5, tokenBudget: 512, preferObservations: false)
            for hit in recall.recall(query) where !seen.contains(hit.unit.id) {
                seen.insert(hit.unit.id)
                pooled.append(hit.unit)
            }
        }
        return pooled
    }

    // MARK: - Prompts

    static func systemPrompt(disposition: MemoryDisposition) -> String {
        var text = """
        You maintain OBSERVATIONS: concise, deduplicated beliefs about the user, built from FACTS. \
        Given new FACTS and EXISTING observations, output actions, one per line, and nothing else:
        CREATE: <observation text>
        UPDATE O<id>: <complete new text>
        DELETE O<id>
        Rules: PREFER UPDATE OVER CREATE. ONE observation per distinct facet — match by entity/facet, not topic. \
        When a state changes, update concisely and keep the history (e.g. "User owned a Honda Civic; sold it on 2025-03-15"). \
        Never delete event records. Never calculate or derive numbers. DELETE only when directly superseded or contradicted. \
        Keep each observation under 30 words, third person. Output NONE when nothing changes.
        """
        let traits = disposition.promptDescription
        if !traits.isEmpty { text += "\nDisposition: \(traits)" }
        return text
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func userPrompt(facts: [MemoryUnit], observations: [MemoryUnit]) -> String {
        var out = "FACTS:\n"
        for (index, fact) in facts.enumerated() {
            var meta = "mentioned=\(dateFormatter.string(from: fact.mentionedAt))"
            if let start = fact.occurredStart { meta += ", occurred=\(dateFormatter.string(from: start))" }
            out += "[F\(index + 1)] \(fact.text) (\(meta))\n"
        }
        out += "\nEXISTING OBSERVATIONS:\n"
        if observations.isEmpty {
            out += "(none)\n"
        } else {
            for obs in observations {
                out += "[O\(obs.id)] \(obs.text) (proof=\(obs.proofCount))\n"
            }
        }
        out += "\nACTIONS:"
        return out
    }

    // MARK: - Parsing

    /// Labeled-line parser. Unknown lines are ignored; `NONE` yields [].
    static func parse(_ raw: String) -> [Action] {
        var actions: [Action] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line.removeFirst(2) }
            let upper = line.uppercased()
            if upper.hasPrefix("CREATE:") {
                let text = line.dropFirst("CREATE:".count).trimmingCharacters(in: .whitespaces)
                if MemoryFactExtraction.isAcceptable(text) { actions.append(.create(text)) }
            } else if upper.hasPrefix("UPDATE") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let head = line[line.index(line.startIndex, offsetBy: 6)..<colon]
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let id = parseID(head), MemoryFactExtraction.isAcceptable(text) { actions.append(.update(id, text)) }
            } else if upper.hasPrefix("DELETE") {
                if let id = parseID(line.dropFirst(6)) { actions.append(.delete(id)) }
            }
        }
        return actions
    }

    private static func parseID(_ fragment: Substring) -> Int64? {
        let digits = fragment.filter(\.isNumber)
        return digits.isEmpty ? nil : Int64(digits)
    }

    // MARK: - Apply

    private func apply(_ actions: [Action], batch: [MemoryUnit], existing: [MemoryUnit]) -> Bool {
        let existingIDs = Set(existing.map(\.id))
        var changed = false
        var updatedIDs = Set<Int64>()
        for action in actions {
            switch action {
            case .create(let text):
                changed = create(text, batch: batch) || changed
            case .update(let id, let text):
                // At most one update per observation; only pooled ids are trusted.
                guard existingIDs.contains(id), !updatedIDs.contains(id),
                      let current = store.fetchUnit(id: id) else { continue }
                updatedIDs.insert(id)
                changed = rewrite(current, text: text, batch: batch) || changed
            case .delete(let id):
                guard existingIDs.contains(id) else { continue }
                store.deleteUnit(id: id)
                changed = true
            }
        }
        return changed
    }

    private func create(_ text: String, batch: [MemoryUnit]) -> Bool {
        guard let vector = embedder.generateVector(for: text) else { return false }
        // Dedup guard: an existing near-identical belief is updated instead.
        if let twin = nearestObservation(to: vector), twin.1 >= embedder.calibration.dedupThreshold {
            return rewrite(twin.0, text: text, batch: batch)
        }
        let evidence = Self.evidence(in: batch, for: vector)
        let id = store.insertUnit(
            text: text, vector: vector, factType: .observation, source: "consolidation",
            proofCount: max(1, evidence.count), sourceIDs: evidence.map(\.id), bank: MemoryBanks.activeCharacter())
        guard id > 0 else { return false }
        store.linkEntities(unitID: id, names: Array(Set(evidence.flatMap(\.entities))))
        return true
    }

    private func rewrite(_ observation: MemoryUnit, text: String, batch: [MemoryUnit]) -> Bool {
        guard let vector = embedder.generateVector(for: text) else { return false }
        let evidence = Self.evidence(in: batch, for: vector)
        let sources = Array(Set(observation.sourceIDs + evidence.map(\.id)))
        store.updateObservation(
            id: observation.id, text: text, vector: vector,
            proofCount: max(observation.proofCount + evidence.count, sources.count), sourceIDs: sources)
        store.linkEntities(unitID: observation.id, names: Array(Set(evidence.flatMap(\.entities))))
        return true
    }

    private func nearestObservation(to vector: [Double]) -> (MemoryUnit, Double)? {
        let model = embedder.activeModelID
        return store.fetchUnits(factTypes: [.observation])
            .filter { $0.vector.count == vector.count && $0.vectorModel == model }
            .map { ($0, EmbeddingService.cosineSimilarity(vector, $0.vector)) }
            .max { $0.1 < $1.1 }
    }

    /// Batch facts that support an observation; all of them when vectors
    /// are unavailable (zero-vector simulator builds).
    static func evidence(in batch: [MemoryUnit], for vector: [Double]) -> [MemoryUnit] {
        let related = batch.filter {
            $0.vector.count == vector.count && EmbeddingService.cosineSimilarity(vector, $0.vector) >= evidenceFloor
        }
        return related.isEmpty ? batch : related
    }
}
