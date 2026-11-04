//
//  AgenticMemoryTests.swift
//  NeuraLinkTests
//
//  Unit tests for the agentic memory layer (docs/AGENTIC_MEMORY.md):
//  tokeniser/BM25, temporal parsing, entity extraction, fact-extraction
//  parsers, consolidation parsing, recall fusion/boosts, and end-to-end
//  retain → recall → consolidate through the shared MemoryStore with a
//  scripted LLM stub.
//

import Foundation
import Testing

@testable import NeuraLink

// MARK: - Stub LLM

struct StubMemoryLLM: MemoryLLM {
    let tier: MemoryLLMTier
    let reply: String?

    func complete(system: String, user: String, maxTokens: Int) async -> String? { reply }
}

private func makeUnit(
    id: Int64, text: String, factType: MemoryFactType = .world, mentionedAt: Date = Date(),
    occurredStart: Date? = nil, proofCount: Int = 1, sourceIDs: [Int64] = [], pinned: Bool = false
) -> MemoryUnit {
    MemoryUnit(
        id: id, text: text, context: "", vector: [], vectorModel: "nl", bank: "", factType: factType, source: "test", pinned: pinned,
        createdAt: mentionedAt, mentionedAt: mentionedAt, occurredStart: occurredStart, occurredEnd: occurredStart,
        proofCount: proofCount, sourceIDs: sourceIDs, consolidatedAt: nil,
        tokens: MemoryTextIndex.tokenString(for: text), entities: [])
}

// MARK: - Text index

@MainActor
@Suite("Agentic memory – text index")
struct MemoryTextIndexTests {

    @Test("Tokeniser lowercases, drops stop words and stems inflections onto one key")
    func tokenise() {
        let tokens = MemoryTextIndex.tokens(for: "The User LIKES spicy Cats and dogs")
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("user"))
        #expect(tokens.contains("spici"))
        #expect(tokens.contains("cat"))
        #expect(tokens.contains("dog"))
        #expect(MemoryTextIndex.tokens(for: "likes") == MemoryTextIndex.tokens(for: "like"))
        #expect(MemoryTextIndex.tokens(for: "named") == MemoryTextIndex.tokens(for: "name"))
        #expect(MemoryTextIndex.tokens(for: "cat's") == MemoryTextIndex.tokens(for: "cat"))
        #expect(MemoryTextIndex.tokens(for: "adopted") == MemoryTextIndex.tokens(for: "adopt"))
        #expect(MemoryTextIndex.tokens(for: "movies") == MemoryTextIndex.tokens(for: "movie"))
        #expect(MemoryTextIndex.tokens(for: "cities") == MemoryTextIndex.tokens(for: "city"))
        #expect(MemoryTextIndex.tokens(for: "my mum") == MemoryTextIndex.tokens(for: "mother"))
    }

    @Test("BM25 ranks the document sharing more query terms first")
    func bm25Ranking() {
        let docs = [
            MemoryTextIndex.Document(id: 1, tokens: MemoryTextIndex.tokenString(for: "User has a cat named Rex.")),
            MemoryTextIndex.Document(id: 2, tokens: MemoryTextIndex.tokenString(for: "User lives in Tokyo.")),
            MemoryTextIndex.Document(id: 3, tokens: MemoryTextIndex.tokenString(for: "User adopted the cat last year."))
        ]
        let ranked = MemoryTextIndex.bm25(query: "what is the name of my cat rex", documents: docs)
        #expect(ranked.first?.0 == 1)
        #expect(ranked.map(\.0).contains(3))
        #expect(!ranked.map(\.0).contains(2))
    }
}

// MARK: - Temporal

@MainActor
@Suite("Agentic memory – temporal parser")
struct MemoryTemporalParserTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    @Test("Yesterday resolves to the previous day")
    func yesterday() throws {
        let window = try #require(MemoryTemporalParser.window(in: "what did I say yesterday?", now: now))
        #expect(window.contains(now.addingTimeInterval(-86_400)))
        #expect(!window.contains(now))
    }

    @Test("N days ago and last week resolve to windows containing the date")
    func relative() throws {
        let threeDays = try #require(MemoryTemporalParser.window(in: "the call 3 days ago", now: now))
        #expect(threeDays.contains(now.addingTimeInterval(-3 * 86_400)))
        let lastWeek = try #require(MemoryTemporalParser.window(in: "our chat last week", now: now))
        #expect(lastWeek.contains(now.addingTimeInterval(-7 * 86_400)))
        #expect(!lastWeek.contains(now))
    }

    @Test("Month names and ISO spans resolve; plain text does not")
    func absolute() throws {
        let march = try #require(MemoryTemporalParser.window(in: "the trip in March 2025", now: now))
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.month, from: march.start) == 3)
        #expect(cal.component(.year, from: march.start) == 2025)
        #expect(MemoryTemporalParser.window(in: "tell me about cats", now: now) == nil)

        let span = try #require(MemoryTemporalParser.span(from: "2026-09-20/2026-09-22", reference: now))
        #expect(span.1.timeIntervalSince(span.0) > 2 * 86_400)
        let year = try #require(MemoryTemporalParser.span(from: "2015", reference: now))
        #expect(cal.component(.year, from: year.0) == 2015)
        #expect(cal.component(.month, from: year.1) == 12)
        #expect(MemoryTemporalParser.span(from: "null", reference: now) == nil)
    }

    @Test("Proximity is 1 at the midpoint and 0 at the edge")
    func proximity() {
        let window = MemoryTimeWindow(start: now, end: now.addingTimeInterval(10 * 86_400))
        #expect(window.proximity(of: now.addingTimeInterval(5 * 86_400)) == 1)
        #expect(window.proximity(of: now) == 0)
    }
}

// MARK: - Entities

@MainActor
@Suite("Agentic memory – entity extractor")
struct MemoryEntityExtractorTests {

    @Test("User entity is included and capitalised names are found")
    func entities() {
        let names = MemoryEntityExtractor.entities(in: "My roommate Emily moved to Berlin.", includeUser: true)
        #expect(names.contains("user"))
        #expect(names.contains("Emily"))
        #expect(names.contains("Berlin"))
        #expect(!names.contains("My"))
    }

    @Test("Sentence-initial noise words are not entities")
    func noise() {
        let names = MemoryEntityExtractor.entities(in: "Yes. Thanks. I think so.", includeUser: false)
        #expect(names.isEmpty)
        #expect(MemoryEntityExtractor.isAboutUser("User likes sushi."))
        #expect(!MemoryEntityExtractor.isAboutUser("Emily likes sushi."))
    }
}

// MARK: - Fact extraction parsers

@MainActor
@Suite("Agentic memory – fact extraction")
struct MemoryFactExtractionTests {
    private let reference = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    @Test("Cloud JSON is parsed with dates, types, entities and causality")
    func parseCloud() throws {
        let raw = """
        ```json
        [{"what": "User adopted a cat named Rex.", "when": "2026-09-20", "who": ["user", "Rex"], "type": "world", "caused_by": null},
         {"what": "Sonya suggested cat toys to the user.", "when": null, "who": ["user"], "type": "experience", "caused_by": 0},
         {"what": "short", "when": null, "who": [], "type": "world"}]
        ```
        """
        let facts = MemoryFactExtraction.parseCloud(raw, reference: reference)
        #expect(facts.count == 2)
        let first = try #require(facts.first)
        #expect(first.factType == .world)
        #expect(first.occurredStart != nil)
        #expect(first.entities.contains("user"))
        #expect(first.entities.contains("Rex"))
        #expect(facts[1].factType == .experience)
        #expect(facts[1].causedByIndex == 0)
    }

    @Test("Cloud parser tolerates a facts wrapper and rejects garbage")
    func parseCloudWrapper() {
        let wrapped = MemoryFactExtraction.parseCloud(#"{"facts": [{"what": "User works as a nurse in Osaka."}]}"#, reference: reference)
        #expect(wrapped.count == 1)
        #expect(MemoryFactExtraction.parseCloud("Sure! Here are no facts.", reference: reference).isEmpty)
        #expect(MemoryFactExtraction.parseCloud("[]", reference: reference).isEmpty)
    }

    @Test("Local output passes through the strict fact gates")
    func parseLocal() {
        let facts = MemoryFactExtraction.parseLocal("User lives in Tokyo with a dog.\nI think that is nice.\nNONE")
        #expect(facts.count == 1)
        #expect(facts.first?.entities.contains("user") == true)
        #expect(facts.first?.entities.contains("Tokyo") == true)
    }

    @Test("Turns are chunked by character budget")
    func chunking() {
        let turns = (0..<6).map { _ in
            MemoryFactExtraction.Turn(role: "user", text: String(repeating: "x", count: 400), timestamp: reference)
        }
        let chunks = MemoryRetain.chunk(turns, maxCharacters: 1000)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count == 2 })
    }
}

// MARK: - Consolidation parser

@MainActor
@Suite("Agentic memory – consolidation")
struct MemoryConsolidatorParseTests {

    @Test("CREATE / UPDATE / DELETE lines are parsed; NONE yields nothing")
    func parse() {
        let actions = MemoryConsolidator.parse("""
        CREATE: User owns a cat named Rex.
        - UPDATE O12: User lived in Tokyo; moved to Osaka on 2026-09-01.
        DELETE O7
        Some chatter the model added.
        """)
        #expect(actions == [
            .create("User owns a cat named Rex."),
            .update(12, "User lived in Tokyo; moved to Osaka on 2026-09-01."),
            .delete(7)
        ])
        #expect(MemoryConsolidator.parse("NONE").isEmpty)
        #expect(MemoryConsolidator.parse("").isEmpty)
    }

    @Test("Prompt lists facts and observations with ids")
    func prompt() {
        let prompt = MemoryConsolidator.userPrompt(
            facts: [makeUnit(id: 1, text: "User likes ramen.")],
            observations: [makeUnit(id: 9, text: "User enjoys Japanese food.", factType: .observation, proofCount: 2)])
        #expect(prompt.contains("[F1] User likes ramen."))
        #expect(prompt.contains("[O9] User enjoys Japanese food. (proof=2)"))
        #expect(MemoryConsolidator.systemPrompt(disposition: .neutral).contains("PREFER UPDATE OVER CREATE"))
        #expect(MemoryConsolidator.systemPrompt(disposition: MemoryDisposition(skepticism: 5, literalism: 3, empathy: 3))
            .contains("highly skeptical"))
    }
}

// MARK: - Recall (pure)

@MainActor
@Suite("Agentic memory – recall fusion")
struct MemoryRecallFusionTests {

    @Test("RRF favours a unit ranked by two arms over a unit ranked by one")
    func fusion() {
        let fused = MemoryRecall.fuse([.semantic: [1, 2], .keyword: [2, 3]])
        #expect(fused.first?.id == 2)
        #expect(fused.count == 3)
    }

    @Test("Budget selection skips units that do not fit")
    func budget() {
        let small = makeUnit(id: 1, text: "User likes tea.")
        let huge = makeUnit(id: 2, text: String(repeating: "long ", count: 200))
        let hits = [
            MemoryRecallHit(unit: huge, score: 1, arms: []),
            MemoryRecallHit(unit: small, score: 0.5, arms: [])
        ]
        let picked = MemoryRecall.selectWithinBudget(hits, maxResults: 5, tokenBudget: 20)
        #expect(picked.map(\.id) == [1])
    }

    @Test("Facts covered by a returned observation are dropped")
    func preferObservations() {
        let fact = makeUnit(id: 1, text: "User adopted a cat named Rex.")
        let other = makeUnit(id: 2, text: "User lives in Tokyo.")
        let obs = makeUnit(id: 3, text: "User owns a cat, Rex.", factType: .observation, proofCount: 2, sourceIDs: [1])
        let hits = [obs, fact, other].map { MemoryRecallHit(unit: $0, score: 1, arms: []) }
        #expect(MemoryRecall.preferObservations(hits).map(\.id) == [3, 2])
    }

    @Test("Keyword arm surfaces the matching unit without vectors and recency boosts newer units")
    func keywordAndRecency() {
        let recall = MemoryRecall()
        let old = makeUnit(id: 1, text: "User adopted a cat named Rex.", mentionedAt: Date().addingTimeInterval(-90 * 86_400))
        let new = makeUnit(id: 2, text: "User adopted a cat named Rex.", mentionedAt: Date())
        let unrelated = makeUnit(id: 3, text: "User lives in Tokyo.")
        let hits = recall.recall(
            MemoryRecallQuery(text: "what is my cat's name?"),
            candidates: [old, new, unrelated], queryVector: [])
        #expect(hits.map(\.id).contains(1))
        #expect(hits.map(\.id).contains(2))
        #expect(!hits.map(\.id).contains(3))
        #expect(hits.allSatisfy { $0.arms.contains(.keyword) })
    }

    @Test("Temporal arm restricts to the window and bullet lines carry dates")
    func temporalArm() {
        let recall = MemoryRecall()
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        let inWindow = makeUnit(id: 1, text: "User went hiking with Emily.", occurredStart: yesterday)
        let outside = makeUnit(id: 2, text: "User went hiking with Emily.", occurredStart: now.addingTimeInterval(-30 * 86_400))
        let hits = recall.recall(
            MemoryRecallQuery(text: "what did I do yesterday?", now: now),
            candidates: [inWindow, outside], queryVector: [])
        #expect(hits.first?.id == 1)
        #expect(hits.first?.arms.contains(.temporal) == true)
        let line = MemoryRecall.bulletLines(Array(hits.prefix(1))).first ?? ""
        #expect(line.hasPrefix("- ("))
    }
}

// MARK: - End-to-end through the store

@MainActor
@Suite("Agentic memory – store round trip", .serialized)
struct AgenticMemoryStoreTests {
    private let marker = "Zyqx"

    @Test("Retained facts are entity-linked and recalled by keyword and entity graph")
    func retainAndRecall() throws {
        let retain = MemoryRetain(llm: StubMemoryLLM(tier: .none, reply: nil))
        let factID = retain.retainFact(
            ExtractedFact(text: "User has a parrot named \(marker)bird.", entities: ["user", "\(marker)bird"]),
            source: "test")
        #expect(factID > 0)
        let unit = try #require(MemoryStore.shared.fetchUnit(id: factID))
        #expect(unit.factType == .world)
        #expect(unit.entities.contains("user"))
        #expect(unit.entities.contains("\(marker)bird"))

        let rawID = retain.retainRaw(text: "I love feeding \(marker)bird sunflower seeds", source: "user")
        #expect(rawID > 0)

        let hits = MemoryRecall.shared.recall(MemoryRecallQuery(
            text: "tell me about \(marker)bird", factTypes: [.world, .raw], maxResults: 5))
        #expect(hits.map(\.id).contains(factID))
        #expect(hits.map(\.id).contains(rawID))

        MemoryStore.shared.deleteUnit(id: factID)
        MemoryStore.shared.deleteUnit(id: rawID)
    }

    @Test("Cloud retain stores dated facts and causal links; consolidation creates an observation")
    func retainConsolidate() async throws {
        let reference = Date()
        let json = """
        [{"what": "User adopted a hamster named \(marker)ham on 2026-09-20.", "when": "2026-09-20", "who": ["user"], "type": "world"},
         {"what": "User bought a hamster wheel for \(marker)ham.", "when": null, "who": ["user"], "type": "world", "caused_by": 0}]
        """
        let retain = MemoryRetain(llm: StubMemoryLLM(tier: .cloud, reply: json))
        let turns = [MemoryFactExtraction.Turn(role: "user", text: "I adopted a hamster, \(marker)ham!", timestamp: reference)]
        let stored = await retain.retain(turns: turns)
        #expect(stored == 2)

        let units = MemoryStore.shared.fetchUnits(factTypes: [.world]).filter { $0.text.contains("\(marker)ham") }
        #expect(units.count == 2)
        let dated = try #require(units.first { $0.occurredStart != nil })
        #expect(Calendar.current.component(.day, from: dated.occurredStart!) == 20)
        let links = MemoryStore.shared.fetchLinks(touching: units.map(\.id))
        #expect(links.contains { $0.kind == .causedBy })

        let consolidator = MemoryConsolidator(
            llm: StubMemoryLLM(tier: .cloud, reply: "CREATE: User owns a hamster named \(marker)ham."))
        let changed = await consolidator.consolidate(batch: units)
        #expect(changed)
        let observation = try #require(
            MemoryStore.shared.fetchUnits(factTypes: [.observation]).first { $0.text.contains("\(marker)ham") })
        #expect(observation.proofCount >= 1)
        #expect(!observation.sourceIDs.isEmpty)
        #expect(MemoryStore.shared.fetchUnconsolidatedUnits(limit: 50).allSatisfy { !$0.text.contains("\(marker)ham") })

        // Recall prefers the observation and hides the facts it covers.
        let hits = MemoryRecall.shared.recall(MemoryRecallQuery(text: "hamster \(marker)ham", maxResults: 5))
        #expect(hits.first?.unit.factType == .observation)
        #expect(!hits.contains { observation.sourceIDs.contains($0.id) })

        for unit in units { MemoryStore.shared.deleteUnit(id: unit.id) }
        MemoryStore.shared.deleteUnit(id: observation.id)
    }

    @Test("A dated fact is found by a relative time reference without embeddings")
    func temporalRetention() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        let stamp = ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")!
        let retain = MemoryRetain(llm: StubMemoryLLM(tier: .none, reply: nil))
        var fact = ExtractedFact(text: "User started guitar lessons with a teacher named \(marker)Paulo.")
        let span = try #require(MemoryTemporalParser.span(from: "2026-08-14", reference: stamp))
        fact.occurredStart = span.0
        fact.occurredEnd = span.1
        let id = retain.retainFact(fact, source: "test", mentionedAt: stamp)
        defer { MemoryStore.shared.deleteUnit(id: id) }
        let hits = MemoryRecall.shared.recall(MemoryRecallQuery(
            text: "what new hobby did I pick up last month?", maxResults: 50, tokenBudget: 5_000, now: now))
        #expect(hits.contains { $0.id == id && $0.arms.contains(.temporal) })
    }

    @Test("Mental models are a DB read and refresh from evidence")
    func mentalModels() async {
        let character = "testchar\(marker)"
        let models = MemoryMentalModels(llm: StubMemoryLLM(tier: .cloud, reply: "ANSWER: The user keeps a \(marker) bird."))
        models.ensureDefaults(character: character)
        #expect(MemoryStore.shared.fetchMentalModels(character: character).count >= 2)

        let retain = MemoryRetain(llm: StubMemoryLLM(tier: .none, reply: nil))
        let id = retain.retainFact(ExtractedFact(text: "User keeps a \(marker) bird at home."), source: "test")
        await models.refreshStale(character: character)
        let block = models.promptBlock(character: character)
        #expect(block.contains("\(marker) bird"))
        #expect(MemoryMentalModels.cleanAnswer("UNKNOWN").isEmpty)

        let evidence = MemoryReflect(llm: StubMemoryLLM(tier: .none, reply: nil))
            .evidence(for: "what pet does the user have \(marker)", character: character)
        #expect(evidence.contains("\(marker) bird"))
        MemoryStore.shared.deleteUnit(id: id)
    }
}

// MARK: - Embedding backends

@MainActor
@Suite("Agentic memory – embedding backends", .serialized)
struct EmbeddingBackendTests {

    @Test("Calibration maps the nominal slider onto each backend's cosine scale")
    func calibration() {
        #expect(abs(EmbeddingCalibration.appleNL.queryFloor(nominal: 0.5) - 0.20) < 0.001)
        #expect(abs(EmbeddingCalibration.embeddingGemma.queryFloor(nominal: 0.5) - 0.40) < 0.001)
        #expect(EmbeddingCalibration.embeddingGemma.queryFloor(nominal: 0.3)
                < EmbeddingCalibration.embeddingGemma.queryFloor(nominal: 0.7))
        #expect(EmbeddingCalibration.appleNL.queryFloor(nominal: 5) == 1)
    }

    @Test("Semantic arm ignores vectors from another backend")
    func vectorModelFilter() {
        let recall = MemoryRecall()
        let same = MemoryUnit(
            id: 1, text: "User loves hiking in the Alps.", context: "", vector: [1, 0, 0], vectorModel: "nl", bank: "",
            factType: .world, source: "t", pinned: false, createdAt: Date(), mentionedAt: Date(), occurredStart: nil,
            occurredEnd: nil, proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: [])
        let other = MemoryUnit(
            id: 2, text: "User loves hiking in the Alps.", context: "", vector: [1, 0, 0], vectorModel: "other-model", bank: "",
            factType: .world, source: "t", pinned: false, createdAt: Date(), mentionedAt: Date(), occurredStart: nil,
            occurredEnd: nil, proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: [])
        let hits = recall.recall(
            MemoryRecallQuery(text: "zzz"), candidates: [same, other], queryVector: [1, 0, 0], vectorModel: "nl")
        #expect(hits.map(\.id) == [1])
        #expect(hits.first?.arms == [.semantic])
    }

    @Test("Migrator re-embeds rows stored by another backend")
    func migrator() async {
        let id = MemoryStore.shared.insertUnit(
            text: "User keeps a migration marker Zyqxmig.", vector: [0.5, 0.5], factType: .world, source: "test",
            vectorModel: "legacy-model")
        defer { MemoryStore.shared.deleteUnit(id: id) }
        #expect(MemoryStore.shared.countUnits(notEmbeddedWith: EmbeddingService.shared.activeModelID) >= 1)
        let migrated = await EmbeddingMigrator().migrateAll(to: EmbeddingService.shared.activeModelID)
        #expect(migrated >= 1)
        let unit = MemoryStore.shared.fetchUnit(id: id)
        #expect(unit?.vectorModel == EmbeddingService.shared.activeModelID)
        #expect(unit?.vector.count == EmbeddingService.shared.generateVector(for: "probe")?.count)
    }

    @Test("Embedding asset is pinned and fetched from its model repo")
    func assetPin() {
        let asset = RemoteAssetRegistry.embeddingModel
        #expect(asset.integrity?.size == 333_590_944)
        #expect(asset.remoteURL?.absoluteString.contains("ggml-org/embeddinggemma-300M-GGUF") == true)
        #expect(RemoteAssetRegistry.whisperModel.remoteURL?.absoluteString.contains("datasets/Dedicatus/NeuraLink") == true)
    }
}
