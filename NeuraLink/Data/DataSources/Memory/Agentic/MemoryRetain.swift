//
//  MemoryRetain.swift
//  NeuraLink
//
//  Retain orchestrator (docs/AGENTIC_MEMORY.md §Retain). Two paths:
//    - no-LLM: every dialogue turn is stored verbatim as a `raw` unit with
//      tokens, entities and temporal/semantic links (this is what the old
//      RAGManager.store did, plus the links);
//    - LLM: once enough un-retained turns accumulate (or a session ends),
//      they are chunked and passed to fact extraction; each fact becomes a
//      dated, entity-linked world/experience unit and consolidation runs.
//
//  Dual-engine via MemoryLLM; injectable for tests. Modeled on
//  ConversationTitler (NSLock in-flight guard, background Task).
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

final class MemoryRetain: @unchecked Sendable {

    static let shared = MemoryRetain()

    /// Extraction runs once this many un-retained dialogue messages exist.
    /// Local models get a larger batch: each silent generation blocks the
    /// engine for seconds on a 4 GB device, so we amortise it.
    static func batchThreshold(for tier: MemoryLLMTier) -> Int { tier == .cloud ? 4 : 8 }
    /// Max characters per extraction chunk (Hindsight uses 3000 server-side).
    static let chunkCharacters = 1500
    /// Semantic links: per-unit cap (the cosine floor is per backend, see
    /// `EmbeddingCalibration`).
    static let semanticLinkCap = 10
    /// Temporal links: same fact type within 24 h, cap per unit.
    static let temporalLinkCap = 20

    private static let watermarkKey = "com.neuralink.memory.retain.lastMessageID"

    private let store: MemoryStore
    private let embedder: EmbeddingService
    private let settings: MemorySettings
    private let llm: MemoryLLM
    private let lock = NSLock()
    private var inFlight = false
    private var started = false

    init(
        store: MemoryStore = .shared,
        embedder: EmbeddingService = .shared,
        settings: MemorySettings = .shared,
        llm: MemoryLLM = LiveMemoryLLM()
    ) {
        self.store = store
        self.embedder = embedder
        self.settings = settings
        self.llm = llm
    }

    // MARK: - Wiring

    /// Installs the session-boundary observer so pending turns are flushed
    /// through extraction when a chat ends, and seeds the standing mental
    /// models for the active character. Idempotent; called at app launch.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: SessionLifecycle.sessionDidEnd, object: nil, queue: .main
        ) { _ in
            MemoryRetain.shared.maybeRetain(force: true)
        }
        let character = RealtimeChatState.shared.selectedCharacterName
        Task.detached(priority: .background) {
            await EmbeddingService.shared.restorePreferredBackend()
            MemoryMentalModels.shared.ensureDefaults(character: character)
        }
    }

    // MARK: - No-LLM paths

    /// Stores one dialogue turn verbatim (`raw`). Returns the new unit id.
    @discardableResult
    func retainRaw(text: String, source: String, mentionedAt: Date = Date()) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !trimmed.isEmpty else { return -1 }
        guard let vector = embedder.generateVector(for: trimmed) else { return -1 }
        let id = store.insertUnit(
            text: trimmed, vector: vector, factType: .raw, source: source, mentionedAt: mentionedAt,
            bank: MemoryBanks.bank(for: .raw, source: source, character: MemoryBanks.activeCharacter()))
        guard id > 0 else { return -1 }
        store.linkEntities(unitID: id, names: MemoryEntityExtractor.entities(in: trimmed, includeUser: source == "user"))
        link(unitID: id, vector: vector, factType: .raw, mentionedAt: mentionedAt)
        return id
    }

    /// Stores an already-structured fact (tool call, legacy storeFact,
    /// tests). Entities are extracted from the text when none are given.
    @discardableResult
    func retainFact(_ fact: ExtractedFact, source: String, mentionedAt: Date = Date()) -> Int64 {
        let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, MemoryFactExtraction.isAcceptable(text) else { return -1 }
        guard let vector = embedder.generateVector(for: text) else { return -1 }
        let id = store.insertUnit(
            text: text, vector: vector, factType: fact.factType, source: source,
            mentionedAt: mentionedAt, occurredStart: fact.occurredStart, occurredEnd: fact.occurredEnd,
            bank: MemoryBanks.bank(for: fact.factType, source: source, character: MemoryBanks.activeCharacter()))
        guard id > 0 else { return -1 }
        let names = fact.entities.isEmpty
            ? MemoryEntityExtractor.entities(in: text, includeUser: MemoryEntityExtractor.isAboutUser(text))
            : fact.entities
        store.linkEntities(unitID: id, names: names)
        link(unitID: id, vector: vector, factType: fact.factType, mentionedAt: mentionedAt)
        return id
    }

    /// Temporal links to same-type units within 24 h (weight
    /// `max(0.3, 1 − Δh/24)`) and semantic links to the nearest units above
    /// the cosine floor.
    func link(unitID: Int64, vector: [Double], factType: MemoryFactType, mentionedAt: Date) {
        let units = store.fetchUnits(factTypes: [factType]).filter { $0.id != unitID }
        var links: [MemoryLink] = []

        let temporal = units
            .map { ($0, abs($0.mentionedAt.timeIntervalSince(mentionedAt)) / 3600) }
            .filter { $0.1 <= 24 }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.temporalLinkCap)
        for (unit, hours) in temporal {
            links.append(MemoryLink(fromID: unitID, toID: unit.id, kind: .temporal, weight: max(0.3, 1 - hours / 24)))
        }

        let linkFloor = embedder.calibration.semanticLinkFloor
        let model = embedder.activeModelID
        let semantic = units
            .filter { $0.vector.count == vector.count && $0.vectorModel == model }
            .map { ($0, EmbeddingService.cosineSimilarity(vector, $0.vector)) }
            .filter { $0.1 >= linkFloor && $0.1 < 0.9999 }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.semanticLinkCap)
        for (unit, sim) in semantic {
            links.append(MemoryLink(fromID: unitID, toID: unit.id, kind: .semantic, weight: sim))
        }
        store.insertLinks(links)
    }

    // MARK: - LLM path

    /// Runs extraction on un-retained dialogue when the batch threshold is
    /// reached (`force` flushes whatever is pending, e.g. at session end).
    /// Fire-and-forget; no-ops when memory is off or nothing is pending.
    func maybeRetain(force: Bool = false) {
        guard settings.isEnabled, llm.tier != .none else { return }
        let pending = pendingTurns()
        guard !pending.isEmpty, force || pending.count >= Self.batchThreshold(for: llm.tier) else { return }

        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.inFlight = false; self.lock.unlock() }
            let stored = await self.retain(turns: pending.map(\.turn))
            self.advanceWatermark(to: pending.map(\.id).max() ?? 0)
            nlLog("[MemoryRetain] Retained \(pending.count) turns → \(stored) facts (\(self.llm.tier))", level: .info)
            if stored > 0 {
                await MemoryConsolidator.shared.consolidatePending()
            }
        }
    }

    /// Extracts and persists facts from `turns`. Returns how many were stored.
    func retain(turns: [MemoryFactExtraction.Turn]) async -> Int {
        var stored = 0
        for chunk in Self.chunk(turns, maxCharacters: Self.chunkCharacters) {
            let facts = await extract(from: chunk)
            let reference = chunk.last?.timestamp ?? Date()
            stored += persist(facts, mentionedAt: reference).count
        }
        return stored
    }

    func extract(from turns: [MemoryFactExtraction.Turn]) async -> [ExtractedFact] {
        guard !turns.isEmpty else { return [] }
        let assistant = RealtimeChatState.shared.selectedCharacterName.capitalized
        switch llm.tier {
        case .cloud:
            guard let raw = await llm.complete(
                system: MemoryFactExtraction.cloudSystemPrompt(assistantName: assistant),
                user: MemoryFactExtraction.cloudUserPrompt(turns: turns, assistantName: assistant),
                maxTokens: MemoryFactExtraction.cloudMaxTokens)
            else { return [] }
            return MemoryFactExtraction.parseCloud(raw, reference: turns.last?.timestamp ?? Date())
        case .local:
            guard let raw = await llm.complete(
                system: "", user: MemoryFactExtraction.localPrompt(turns: turns),
                maxTokens: MemoryFactExtraction.localMaxTokens)
            else { return [] }
            return MemoryFactExtraction.parseLocal(raw)
        case .none:
            return []
        }
    }

    /// Persists facts and their causal links. Returns the stored unit ids in
    /// input order (facts that failed the gates are simply absent).
    @discardableResult
    func persist(_ facts: [ExtractedFact], mentionedAt: Date) -> [Int64] {
        var ids: [Int64?] = []
        for fact in facts {
            let id = retainFact(fact, source: "retain", mentionedAt: mentionedAt)
            ids.append(id > 0 ? id : nil)
            nlLogSensitive("[MemoryRetain] fact: \(fact.text)", level: .info)
        }
        var causal: [MemoryLink] = []
        for (index, fact) in facts.enumerated() {
            guard let cause = fact.causedByIndex, cause < ids.count,
                  let from = ids[index], let to = ids[cause] else { continue }
            causal.append(MemoryLink(fromID: from, toID: to, kind: .causedBy, weight: 1.0))
        }
        store.insertLinks(causal)
        return ids.compactMap { $0 }
    }

    /// Splits turns into consecutive chunks of at most `maxCharacters`.
    static func chunk(_ turns: [MemoryFactExtraction.Turn], maxCharacters: Int) -> [[MemoryFactExtraction.Turn]] {
        var chunks: [[MemoryFactExtraction.Turn]] = []
        var current: [MemoryFactExtraction.Turn] = []
        var size = 0
        for turn in turns {
            if !current.isEmpty, size + turn.text.count > maxCharacters {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(turn)
            size += turn.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Watermark

    private struct PendingTurn {
        let id: Int64
        let turn: MemoryFactExtraction.Turn
    }

    /// Dialogue messages newer than the watermark, oldest first.
    private func pendingTurns() -> [PendingTurn] {
        let watermark = UserDefaults.standard.object(forKey: Self.watermarkKey) as? Int64 ?? 0
        return store.fetchRecentMessagesAcrossAll(limit: 60)
            .filter { $0.id > watermark && $0.kind == "message" && ($0.isUser || $0.isAssistant) }
            .sorted { $0.id < $1.id }
            .map { PendingTurn(id: $0.id, turn: .init(role: $0.role, text: $0.content, timestamp: $0.timestamp)) }
    }

    private func advanceWatermark(to id: Int64) {
        guard id > 0 else { return }
        UserDefaults.standard.set(id, forKey: Self.watermarkKey)
    }
}
