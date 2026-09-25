# Agentic Memory (Hindsight-style)

NeuraLink's long-term memory was a single-signal RAG: every turn was embedded, and retrieval was `cosine × recency` over one flat table. This document describes the replacement, an on-device port of the architecture behind [Hindsight](https://hindsight.vectorize.io/) (Vectorize; paper *"Hindsight is 20/20: Building Agent Memory that Retains, Recalls, and Reflects"*, arXiv 2512.12818). The old entry points (`RAGManager.store / fetchContext / storeFact / fetchFacts`) still exist as a facade so callers did not change.

Everything runs on the phone: SQLite (optionally SQLCipher), Apple `NLEmbedding` vectors, `NLTagger` entities, and one small LLM call per background step (OpenAI `gpt-4o-mini` via `OpenAIChatClient`, or the local model via `runSilentGeneration`). Recall itself never calls an LLM.

## What changed, in one table

| Concern | Before | Now |
|---|---|---|
| Memory types | one table, `source` tag | `raw` dialogue, `world` facts, `experience` (what the assistant did), `observation` (consolidated belief) + mental models |
| Ingest | embed every turn | same (no-LLM `raw` path) **plus** batched LLM fact extraction with dates, entities and causal links |
| Retrieval | cosine ≥ floor × recency | four arms (semantic, BM25, entity-graph, temporal) → RRF fusion → boosted rerank → token budget |
| Prompt grounding | all KG facts dumped, top-3 cosine facts | zero-LLM mental-model block (stable, KV-cache friendly) + per-turn hybrid recall |
| Agentic lookup | none | `search_memory` tool: the model decides when to query memory mid-conversation |
| Consolidation | none | background CREATE/UPDATE/DELETE of observations with a cosine dedup guard |
| Local models | fact extraction disabled for both shipped tiers | enabled through the same orchestrator, with the strict `LocalLLMFactExtractor` gates |

## Files

All under `NeuraLink/Data/DataSources/Memory/Agentic/` unless noted.

| File | Role |
|---|---|
| `MemoryUnit.swift` | `MemoryUnit`, `MemoryFactType`, `MemoryEntity`, `MemoryLink`, `MentalModel`, `ExtractedFact` |
| `MemoryStore+Units.swift` | schema migration (`migrateAgenticMemoryIfNeeded`), unit CRUD |
| `MemoryStore+Entities.swift` | `memory_entities`, `memory_unit_entities`, `memory_links` |
| `MemoryStore+MentalModels.swift` | `mental_models` CRUD |
| `MemoryTextIndex.swift` | tokeniser (NLTokenizer + light stemming) and Okapi BM25 |
| `MemoryTemporalParser.swift` | query → time window; fact `when` → absolute span |
| `MemoryEntityExtractor.swift` | NLTagger names + capitalised-word fallback; always adds `user` |
| `MemoryRecall.swift` | the four arms, RRF, rerank, budget, bullet formatting |
| `MemoryFactExtraction.swift` | cloud JSON prompt/parser; local labeled-line prompt/parser |
| `MemoryRetain.swift` | raw path, structured facts, batched LLM extraction, link building, session-end flush |
| `MemoryConsolidator.swift` | observation maintenance |
| `MemoryMentalModels.swift` | standing questions, delta refresh, prompt block |
| `MemoryReflect.swift` | retrieval ladder (`evidence`) and one-call `reflect` |
| `MemoryLLM.swift` | `MemoryLLM` protocol + `LiveMemoryLLM` router (cloud / local / none) |
| `MemoryDisposition.swift` | per-character skepticism / literalism / empathy, verbalised for prompts |
| `../RAGManager.swift` | facade over retain + recall |
| `Domain/Entities/Skills/SearchMemorySkill.swift` | the `search_memory` tool |
| `Presentation/Views/AI/MemoryInsightsSection.swift` | "What X knows" + observations in the Memory sheet |

## Schema

`memories` gained: `fact_type`, `context`, `tokens`, `mentioned_at`, `occurred_start`, `occurred_end`, `proof_count`, `source_ids`, `consolidated_at`. Legacy rows are back-filled once (`source='fact'` → `world`, everything else `raw`; tokens computed). New tables: `memory_entities` (canonical name, NOCASE unique, mention count), `memory_unit_entities`, `memory_links` (`temporal | semantic | entity | caused_by`, weight), `mental_models` (`character`, `slug`, `question`, `content`, `is_stale`, `last_memory_id`). Unit-side rows cascade on delete; `MemoryStore.clear()` wipes the side tables too.

Temporal semantics follow Hindsight: `occurred_*` = when it happened (extracted, nullable), `mentioned_at` = when it was said (the recency anchor), `timestamp` = ingestion.

## Retain

```mermaid
graph LR
    T["dialogue turn"] --> R1["retainRaw<br/>embed + tokens + entities<br/>temporal/semantic links"] --> DB[("memories<br/>fact_type=raw")]
    T --> W["messages watermark"] --> B{"≥ 4 (cloud) / 8 (local)<br/>un-retained turns,<br/>or session end?"}
    B -->|yes| C["chunk ≤ 1500 chars"] --> X["fact extraction<br/>(one LLM call per chunk)"]
    X --> F["world / experience units<br/>occurred dates, entities,<br/>caused_by links"] --> DB
    F --> K["MemoryConsolidator"]
```

* **Raw path** (`MemoryRetain.retainRaw`): what the old `store()` did, plus links. Temporal links join same-type units within 24 h with weight `max(0.3, 1 − Δh/24)` (cap 20); semantic links join the nearest units with cosine ≥ 0.7 (cap 10).
* **LLM path** (`maybeRetain`): triggered from `ChatTimelineStore.logAIMessage` (both engines) and flushed on `SessionLifecycle.sessionDidEnd`. Cloud models get Hindsight's structured extraction (`what / when / who / type / caused_by`, JSON; relative dates converted to absolute using the message dates; `"user"` always included; coreference like *"Emily (user's roommate)"*). Local 1–2B models get the proven line-per-fact prompt and pass through `LocalLLMFactExtractor.parseFacts`' quality gates; their facts are timeless and about the user only.
* **Structured facts** (`retainFact`): `remember_fact` tool calls and the legacy `storeFact` become entity-linked world facts so the graph arm can reach them.

## Recall (TEMPR port)

```mermaid
graph TD
    Q["query"] --> S["semantic<br/>cosine > Memory Quality floor"]
    Q --> K["keyword<br/>BM25 over tokens"]
    S --> G["graph<br/>1-hop from top-20 seeds:<br/>tanh(shared entities × 0.5)<br/>+ semantic link weight<br/>+ causal weight + 1"]
    Q --> TP["temporal<br/>window from query →<br/>units inside, spread over 5 buckets"]
    S & K & G & TP --> RRF["RRF: Σ 1/(60 + rank)"]
    RRF --> RR["rerank: 1/(1+rank) ×<br/>recency × temporal × evidence × pin"]
    RR --> PO["prefer observations<br/>(drop covered facts)"] --> BUD["token budget<br/>(skip, don't truncate)"] --> OUT["hits"]
```

Rerank boosts, mirroring Hindsight's multiplicative form: `(1 + 0.8·w·(recency − 0.5)) × (1 + 0.2·(temporal − 0.5)) × (1 + 0.1·(proof − 0.5)) × (pinned ? 1.15 : 1)`, where `recency = exp(−ageDays / halfLife)`, `temporal` is proximity to the window midpoint (0.5 when the query has no window) and `proof` is `log(1 + proof_count)/log(11)` for observations (0.5 otherwise). `w`, `halfLife` and the semantic floor are the existing `MemorySettings` tunables; the "Memory Quality" slider now only gates the semantic arm, so keyword/entity/temporal hits can still surface a memory whose embedding is weak (or zero, on the simulator).

`MemoryRecallQuery` carries `factTypes`, `maxResults`, `tokenBudget` (≈ 4 chars/token) and `preferObservations`.

## Observations (consolidation)

After every retain batch, `MemoryConsolidator.consolidatePending` takes un-consolidated world/experience facts in batches (8 cloud / 3 local), pools related observations via recall, and asks the LLM for labeled-line actions:

```
CREATE: <text>
UPDATE O<id>: <complete new text>
DELETE O<id>
```

Rules in the prompt are Hindsight's: prefer update over create, one observation per facet, update state changes concisely while keeping history, never delete event records, never compute numbers, delete only when contradicted. Guards on our side: only pooled ids may be updated/deleted, at most one update per id, a CREATE whose embedding is ≥ 0.97 cosine to an existing observation becomes an update (merge), and `proof_count` / `source_ids` accumulate the batch facts that support the belief. Facts are marked consolidated even when the model returns nothing, so a bad batch never wedges the queue. Any change flags mental models stale.

## Mental models

Two standing questions: a global **user profile** and a per-character **relationship** note (`MemoryMentalModels.ensureDefaults`). Refresh is delta-mode: only when stale *and* `MAX(memories.id)` moved since the last refresh; evidence comes from recall (observations preferred, ≤ 900 tokens) and one LLM call answers in ≤ 80 words or `UNKNOWN`. Reading is a DB read: `promptBlock(character:)` goes into the **stable** system prefix on both engines (local: KV-cache-safe because it only changes after background consolidation; OpenAI: session instructions).

## Reflect and the `search_memory` tool

`MemoryReflect.evidence(for:character:)` is Hindsight's retrieval ladder without an LLM: fresh mental models → observations → raw facts/dialogue, descending only while evidence is thin. The `search_memory` tool returns that evidence to the Realtime model, which is told to call it before answering anything that depends on the past. `reflect(question:)` adds one synthesis call (with the character's disposition) for callers that need a finished answer. Local tool calling stays limited to `remember_fact`; the local path gets the same recall per turn in Tier 3 instead.

## Disposition

`MemoryDisposition` (skepticism / literalism / empathy, 1–5, per character in `UserDefaults`) is rendered as sentences and appended to the consolidation, mental-model and reflect prompts, never to recall. Neutral (3/3/3) adds nothing. No UI yet.

## Prompt integration

* **Local** (`LocalLLMMemoryHierarchy`): Tier 1 system prefix gains the mental-model block; Tier 3 is now hybrid recall over knowledge units with a 180-token budget (`[Relevant memories]`).
* **OpenAI** (`OpenAIRealtimeManager+SessionConfig`): instructions gain the mental-model block, a 500-token recall block for the persona, the KG list (unchanged) and the `search_memory` usage rule.

## Budgets and device behaviour

| Step | LLM calls | When |
|---|---|---|
| raw retain | 0 | every turn, detached background task |
| recall | 0 | every local turn / session start / tool call |
| fact extraction | 1 per ≤ 1500-char chunk | every 4 (cloud) or 8 (local) turns, and at session end |
| consolidation | 1 per batch (≤ 4 batches/run) | after extraction stored something |
| mental-model refresh | 1 per stale model | after consolidation changed something |

Local extraction reuses `runSilentGeneration`, which is serialised with user-facing generation; the larger local batch amortises the cost. The JP tier is excluded (`LiveMemoryLLM.tier`), matching the existing "no Tier 3 for LLM-jp" rule.

## Testing

`NeuraLinkTests/AgenticMemoryTests.swift` covers the tokeniser/BM25, temporal parser, entity extractor, both extraction parsers, consolidation parsing/prompts, RRF/budget/observation-preference, keyword + temporal arms without vectors, and a store round trip (retain → links → recall → consolidate → mental model → reflect ladder) using a scripted `MemoryLLM` stub. On the simulator `NLEmbedding` returns zero vectors, so the round-trip tests exercise exactly the arms that the old cosine-only RAG could not.

## Not ported (deliberately)

Cross-encoder reranking (no on-device model; rank-seeded passthrough instead), spreading activation beyond one hop, per-bank visibility tags, directives, knowledge pages, the 10-iteration agentic reflect loop (one ladder pass + one synthesis call instead).
