//
//  MemoryEvalRunner.swift
//  NeuraLink
//
//  Memory evaluation harness. Plays
//  the fixture through retain → consolidate → recall with a scripted LLM so
//  results are deterministic, then scores recall@k, MRR and avoid-violations
//  per question type. Runs in CI (NeuraLinkTests) and on device via the
//  `-nl.debug.memoryEval YES` launch argument, where real embeddings make
//  the semantic arm count. Every unit it inserts is deleted afterwards.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

#if DEBUG

/// Fixed-reply LLM for deterministic harness runs.
struct ScriptedMemoryLLM: MemoryLLM {
    let tier: MemoryLLMTier
    let reply: String?
    func complete(system: String, user: String, maxTokens: Int) async -> String? { reply }
}

struct MemoryEvalReport {
    struct TypeScore {
        var questions = 0
        var hitsAtK = 0
        var reciprocalRankSum = 0.0
        var avoidChecks = 0
        var avoidViolations = 0

        var recallAtK: Double { questions == 0 ? 0 : Double(hitsAtK) / Double(questions) }
        var mrr: Double { questions == 0 ? 0 : reciprocalRankSum / Double(questions) }
        var avoidPrecision: Double { avoidChecks == 0 ? 1 : 1 - Double(avoidViolations) / Double(avoidChecks) }
    }

    var k: Int
    var perType: [String: TypeScore] = [:]
    var failures: [String] = []
    /// Quantiles of each fixture fact's best cosine to another fact
    /// (p10/p50/p90) — the data behind `EmbeddingCalibration`.
    var neighbourSimilarity: (p10: Double, p50: Double, p90: Double) = (0, 0, 0)

    var overall: TypeScore {
        perType.values.reduce(into: TypeScore()) { acc, score in
            acc.questions += score.questions
            acc.hitsAtK += score.hitsAtK
            acc.reciprocalRankSum += score.reciprocalRankSum
            acc.avoidChecks += score.avoidChecks
            acc.avoidViolations += score.avoidViolations
        }
    }

    var summaryLines: [String] {
        var lines = perType.keys.sorted().map { type -> String in
            let s = perType[type]!
            return String(
                format: "[MemoryEval] type=%@ n=%d recall@%d=%.2f mrr=%.2f avoid_precision=%.2f",
                type, s.questions, k, s.recallAtK, s.mrr, s.avoidPrecision)
        }
        let all = overall
        lines.append(String(
            format: "[MemoryEval] overall n=%d recall@%d=%.2f mrr=%.2f avoid_precision=%.2f",
            all.questions, k, all.recallAtK, all.mrr, all.avoidPrecision))
        lines.append(String(
            format: "[MemoryEval] fact↔fact best cosine p10=%.2f p50=%.2f p90=%.2f",
            neighbourSimilarity.p10, neighbourSimilarity.p50, neighbourSimilarity.p90))
        return lines
    }
}

final class MemoryEvalRunner {

    static let k = 5

    private let store: MemoryStore
    private let recall: MemoryRecall
    private let fixtureJSON: String
    private var insertedIDs: [Int64] = []

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(store: MemoryStore = .shared, recall: MemoryRecall = .shared, fixtureJSON: String = MemoryEvalFixture.json) {
        self.store = store
        self.recall = recall
        self.fixtureJSON = fixtureJSON
    }

    // MARK: - Run

    func run() async throws -> MemoryEvalReport {
        defer { cleanup() }
        let cases = try Self.parseCases(fixtureJSON)
        var report = MemoryEvalReport(k: Self.k)
        for evalCase in cases {
            let ids = await ingest(evalCase)
            for question in evalCase.questions {
                score(question, caseID: evalCase.id, ids: ids, now: evalCase.now, report: &report)
            }
        }
        report.neighbourSimilarity = neighbourQuantiles()
        return report
    }

    // MARK: - Ingest

    private func ingest(_ evalCase: EvalCase) async -> [String: Int64] {
        let retain = MemoryRetain(store: store, llm: ScriptedMemoryLLM(tier: .none, reply: nil))
        var ids: [String: Int64] = [:]
        var caseUnits: [MemoryUnit] = []
        for session in evalCase.sessions {
            let stamp = session.date.addingTimeInterval(12 * 3600)
            for turn in session.turns {
                let id = retain.retainRaw(text: turn.text, source: turn.role == "user" ? "user" : "ai", mentionedAt: stamp)
                if id > 0 { insertedIDs.append(id) }
            }
            let facts = session.facts.map { $0.extracted(reference: stamp) }
            let stored = retain.persist(facts, mentionedAt: stamp)
            insertedIDs.append(contentsOf: stored)
            // persist keeps input order; a fact that failed the gates is missing,
            // so re-associate by text.
            let units = store.fetchUnits(ids: stored)
            for fact in session.facts {
                if let unit = units.first(where: { $0.text == fact.what }) {
                    ids[fact.key] = unit.id
                    caseUnits.append(unit)
                }
            }
        }
        if !evalCase.consolidation.isEmpty, !caseUnits.isEmpty {
            let consolidator = MemoryConsolidator(
                store: store, llm: ScriptedMemoryLLM(tier: .cloud, reply: evalCase.consolidation.joined(separator: "\n")),
                recall: recall)
            _ = await consolidator.consolidate(batch: caseUnits)
            let caseIDs = Set(caseUnits.map(\.id))
            for obs in store.fetchUnits(factTypes: [.observation]) where !obs.sourceIDs.filter(caseIDs.contains).isEmpty {
                insertedIDs.append(obs.id)
            }
        }
        return ids
    }

    // MARK: - Score

    private func score(_ question: EvalQuestion, caseID: String, ids: [String: Int64], now: Date, report: inout MemoryEvalReport) {
        let expected = Set(question.expect.compactMap { ids[$0] })
        let avoided = Set(question.avoid.compactMap { ids[$0] })
        let hits = recall.recall(MemoryRecallQuery(
            text: question.text, factTypes: question.factTypes, maxResults: Self.k, tokenBudget: 2_000, now: now))

        var typeScore = report.perType[question.type, default: .init()]
        typeScore.questions += 1

        let expectedRank = hits.firstIndex { Self.covers($0.unit, any: expected) }
        if let rank = expectedRank {
            typeScore.hitsAtK += 1
            typeScore.reciprocalRankSum += 1 / Double(rank + 1)
        } else {
            let window = MemoryTemporalParser.window(in: question.text, now: now)
            let resolved = question.expect.map { key -> String in
                guard let id = ids[key], let unit = store.fetchUnit(id: id) else { return "\(key)=unstored" }
                var line = "\(key)=#\(id) type=\(unit.factType.rawValue) occurred=\(unit.occurredStart.map { "\($0)" } ?? "nil")/\(unit.occurredEnd.map { "\($0)" } ?? "nil")"
                if let window {
                    let start = unit.occurredStart ?? unit.mentionedAt
                    let end = unit.occurredEnd ?? start
                    line += " window=\(window.start)…\(window.end) overlaps=\(start <= window.end && end >= window.start)"
                }
                return line
            }
            let wide = recall.recall(MemoryRecallQuery(
                text: question.text, factTypes: question.factTypes, maxResults: 50, tokenBudget: 100_000,
                preferObservations: false, now: now))
            let diag = recall.lastDiagnostics
            let shown = hits.map { "#\($0.id) \($0.unit.text.prefix(32)) \($0.arms.map(\.rawValue))" }
            let wideIDs = wide.map { "#\($0.id)\($0.arms.map { String($0.rawValue.prefix(1)) })" }
            let armSummary = diag.arms.mapValues { $0.prefix(8).map { $0 } }
            var sims = question.expect.compactMap { key -> String? in
                guard let id = ids[key], let sim = diag.similarity[id] else { return nil }
                return String(format: "%@=%.2f", key, sim)
            }
            sims.append(contentsOf: diag.similarity.sorted { $0.value > $1.value }.prefix(6)
                .map { String(format: "#%lld=%.2f", $0.key, $0.value) })
            report.failures.append(
                "\(caseID): \"\(question.text)\" expected \(resolved) → \(shown) wide=\(wideIDs) "
                + "candidates=\(diag.candidateCount) inWindow=\(diag.inWindowIDs) arms=\(armSummary) sims=\(sims)")
        }

        // A superseded / out-of-window unit may appear, but never above the
        // best expected hit — the right answer has to win.
        if !avoided.isEmpty {
            typeScore.avoidChecks += 1
            let avoidedRank = hits.firstIndex { $0.unit.factType != .observation && avoided.contains($0.unit.id) }
            if let bad = avoidedRank, bad < (expectedRank ?? Int.max) {
                typeScore.avoidViolations += 1
                report.failures.append("\(caseID): \"\(question.text)\" ranked a superseded fact above the answer")
            }
        }
        report.perType[question.type] = typeScore
    }

    /// A unit counts as a hit when it is an expected fact or an observation
    /// consolidated from one.
    private static func covers(_ unit: MemoryUnit, any expected: Set<Int64>) -> Bool {
        if expected.contains(unit.id) { return true }
        return unit.factType == .observation && unit.sourceIDs.contains(where: expected.contains)
    }

    /// Best cosine of every harness fact to any other harness fact.
    private func neighbourQuantiles() -> (p10: Double, p50: Double, p90: Double) {
        let inserted = Set(insertedIDs)
        let facts = store.fetchUnits(factTypes: [.world, .experience]).filter { inserted.contains($0.id) }
        var best: [Double] = []
        for unit in facts where !unit.vector.isEmpty {
            let top = facts.lazy
                .filter { $0.id != unit.id && $0.vector.count == unit.vector.count }
                .map { EmbeddingService.cosineSimilarity(unit.vector, $0.vector) }
                .max() ?? 0
            best.append(top)
        }
        guard !best.isEmpty else { return (0, 0, 0) }
        let sorted = best.sorted()
        func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        return (q(0.1), q(0.5), q(0.9))
    }

    private func cleanup() {
        for id in insertedIDs { store.deleteUnit(id: id) }
        insertedIDs.removeAll()
    }

    // MARK: - Fixture model

    struct EvalFact {
        let key: String
        let what: String
        let when: String?
        let who: [String]
        let type: String
        let causedBy: Int?

        func extracted(reference: Date) -> ExtractedFact {
            var fact = ExtractedFact(text: what)
            fact.factType = type == "experience" ? .experience : .world
            if let when, let span = MemoryTemporalParser.span(from: when, reference: reference) {
                fact.occurredStart = span.0
                fact.occurredEnd = span.1
            }
            fact.entities = MemoryFactExtraction.dedupe(
                who + MemoryEntityExtractor.entities(in: what, includeUser: MemoryEntityExtractor.isAboutUser(what)))
            fact.causedByIndex = causedBy
            return fact
        }
    }

    struct EvalTurn {
        let role: String
        let text: String
    }

    struct EvalSession {
        let date: Date
        let turns: [EvalTurn]
        let facts: [EvalFact]
    }

    struct EvalQuestion {
        let type: String
        let text: String
        let expect: [String]
        let avoid: [String]
        let factTypes: Set<MemoryFactType>
    }

    struct EvalCase {
        let id: String
        let now: Date
        let sessions: [EvalSession]
        let consolidation: [String]
        let questions: [EvalQuestion]
    }

    enum FixtureError: Error { case malformed(String) }

    static func parseCases(_ json: String) throws -> [EvalCase] {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCases = root["cases"] as? [[String: Any]]
        else { throw FixtureError.malformed("root") }

        return try rawCases.map { raw in
            guard let id = raw["id"] as? String else { throw FixtureError.malformed("case id") }
            let nowString = raw["now"] as? String ?? MemoryEvalFixture.defaultNow
            guard let now = dayFormatter.date(from: nowString)?.addingTimeInterval(12 * 3600) else {
                throw FixtureError.malformed("\(id).now")
            }
            let sessions = try (raw["sessions"] as? [[String: Any]] ?? []).map { session -> EvalSession in
                guard let dateString = session["date"] as? String, let date = dayFormatter.date(from: dateString) else {
                    throw FixtureError.malformed("\(id).session.date")
                }
                let turns = (session["turns"] as? [[String: Any]] ?? []).compactMap { turn -> EvalTurn? in
                    guard let role = turn["role"] as? String, let text = turn["text"] as? String else { return nil }
                    return EvalTurn(role: role, text: text)
                }
                let facts = (session["facts"] as? [[String: Any]] ?? []).compactMap { fact -> EvalFact? in
                    guard let key = fact["key"] as? String, let what = fact["what"] as? String else { return nil }
                    return EvalFact(
                        key: key, what: what, when: fact["when"] as? String, who: fact["who"] as? [String] ?? [],
                        type: fact["type"] as? String ?? "world", causedBy: fact["caused_by"] as? Int)
                }
                return EvalSession(date: date, turns: turns, facts: facts)
            }
            let questions = (raw["questions"] as? [[String: Any]] ?? []).compactMap { q -> EvalQuestion? in
                guard let type = q["type"] as? String, let text = q["q"] as? String else { return nil }
                let types = (q["fact_types"] as? [String])?.compactMap(MemoryFactType.init(rawValue:))
                return EvalQuestion(
                    type: type, text: text, expect: q["expect"] as? [String] ?? [], avoid: q["avoid"] as? [String] ?? [],
                    factTypes: types.map(Set.init) ?? MemoryFactType.knowledge)
            }
            return EvalCase(
                id: id, now: now, sessions: sessions,
                consolidation: raw["consolidation"] as? [String] ?? [], questions: questions)
        }
    }
}
#endif
