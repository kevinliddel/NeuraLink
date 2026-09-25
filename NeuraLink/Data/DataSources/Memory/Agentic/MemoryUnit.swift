//
//  MemoryUnit.swift
//  NeuraLink
//
//  Domain models for the agentic memory layer (docs/AGENTIC_MEMORY.md).
//  Modelled on Hindsight's memory network: every row in `memories` is a
//  "memory unit" with a fact type, temporal fields, entity links and an
//  evidence count. `MemoryItem` (the legacy vector-row shape) stays for the
//  timeline/forget flows; new code reads `MemoryUnit`.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

/// What kind of knowledge a memory unit holds.
enum MemoryFactType: String, CaseIterable, Sendable {
    /// Verbatim dialogue chunk (user or assistant turn). No LLM involved.
    case raw
    /// Objective fact about the world / the user, extracted by retain.
    case world
    /// Something the assistant itself did or experienced.
    case experience
    /// Consolidated, deduplicated belief synthesised from several facts.
    case observation

    /// The types recall considers "knowledge" (everything but raw dialogue).
    static let knowledge: Set<MemoryFactType> = [.world, .experience, .observation]
}

/// One row of `memories` with the full agentic-memory column set.
struct MemoryUnit: Identifiable, Sendable {
    let id: Int64
    let text: String
    /// Short surrounding context (e.g. "said during a chat about dinner").
    let context: String
    let vector: [Double]
    let factType: MemoryFactType
    let source: String
    let pinned: Bool
    /// Ingestion time (row creation).
    let createdAt: Date
    /// When the source text was written — the unit's recency anchor.
    let mentionedAt: Date
    /// When the described event happened (nil for timeless state facts).
    let occurredStart: Date?
    let occurredEnd: Date?
    /// Observations: how many source facts back this belief. 1 otherwise.
    let proofCount: Int
    /// Observations: ids of the facts they were consolidated from.
    let sourceIDs: [Int64]
    let consolidatedAt: Date?
    /// Space-separated normalised tokens used by the BM25 arm.
    let tokens: String
    /// Canonical entity names linked to this unit.
    let entities: [String]

    /// Anchor date used for recency and temporal proximity.
    var recencyDate: Date { occurredEnd ?? occurredStart ?? mentionedAt }

    /// Rough token estimate (≈ 4 chars/token) used for prompt budgeting.
    var estimatedTokens: Int { max(1, (text.count + context.count) / 4) }
}

/// A canonical entity ("user", "Emily (user's roommate)", "Tokyo", …).
struct MemoryEntity: Identifiable, Hashable, Sendable {
    let id: Int64
    let canonicalName: String
    let kind: String
    let mentionCount: Int
}

/// Typed edge between two memory units. Weights live in 0...1 except causal
/// links which recall treats as the strongest signal.
struct MemoryLink: Hashable, Sendable {
    enum Kind: String, Sendable {
        case temporal, semantic, entity, causedBy = "caused_by"
    }

    let fromID: Int64
    let toID: Int64
    let kind: Kind
    let weight: Double
}

/// A standing answer to a fixed question about the user / relationship.
/// Reading one is a DB read — no retrieval, no LLM. Refreshed in delta mode
/// after consolidation when new memories arrived since `lastMemoryID`.
struct MentalModel: Identifiable, Sendable {
    let id: Int64
    /// Empty string = global (shared by every character).
    let character: String
    let slug: String
    let question: String
    let content: String
    let isStale: Bool
    let lastRefreshed: Date?
    let lastMemoryID: Int64
}

/// A fact produced by retain before it is persisted.
struct ExtractedFact: Equatable, Sendable {
    var text: String
    var factType: MemoryFactType = .world
    var occurredStart: Date?
    var occurredEnd: Date?
    var entities: [String] = []
    /// Index (in the same extraction batch) of the fact that caused this one.
    var causedByIndex: Int?
}
