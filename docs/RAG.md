# Persistent Long-Term Memory (RAG)

The NeuraLink RAG (Retrieval-Augmented Generation) system provides the AI with a persistent "memory" of past interactions. This allows the AI to remember facts about the user, past topics of discussion, and shared context even after the app is restarted.

## How it Works

1.  **Ingestion**: Every time the user speaks or the AI responds, the text is sent to the `RAGManager`.
2.  **Embedding**: The `EmbeddingService` uses Apple's native `NaturalLanguage` framework (`NLEmbedding`) to convert the text into a 512-dimensional vector.
3.  **Storage**: The text and its corresponding vector are stored in a local SQLite database (`neuralink_memory.sqlite`).
4.  **Retrieval**: When a new query is received, the system generates an embedding for the query and searches the database for the most similar past entries using **Cosine Similarity**.
5.  **Augmentation**: The top relevant results are injected into the LLM's system prompt as "[Long-term Memory Context]".

## Semantic Knowledge Graph

In addition to vector-based memory, NeuraLink implements a **Structured Knowledge Graph**. While RAG is great for fuzzy context, the Knowledge Graph is designed for **explicit facts**.

- **Structure**: (Subject, Predicate, Object) triplets stored in SQLite.
- **Precision**: Facts like "User has a cat named Rex" are stored exactly, preventing hallucinations during recall.
- **Integration**: The AI can explicitly store facts using the `remember_fact` tool.
- **Recall**: All stored facts are formatted as a bulleted list and injected into the AI's system instructions at the start of every session.

This dual-memory system provides both "fuzzy" situational context and "perfect" factual recall.

## System Architecture

```mermaid
graph TD
    User(("User")) --> D1["Speech / Text"] --> LLMManager["LLM Manager"]

    LLMManager --> D2["Query"] --> RAGManager["RAG Manager"]

    RAGManager --> D3["Text"] --> EmbedService["Embedding Service"]
    EmbedService --> D4["Embedding Vector"] --> Vector["Vector Index"]

    RAGManager --> D5["Vector Search"] --> MemStore["Memory Store"]
    MemStore --> D6["SQLite Query"] --> SQLite[("Local SQLite DB")]
    SQLite --> D7["Relevant Chunks"] --> MemStore

    MemStore --> D8["Context"] --> RAGManager
    RAGManager --> D9["Augmented Prompt"] --> LLMManager

    LLMManager --> D10["Request"] --> AIModel["AI Model"]
    AIModel --> D11["Response"] --> LLMManager

    LLMManager --> D12["Store Memory"] --> RAGManager
    RAGManager --> D13["Store Fact"] --> KGManager["Knowledge Graph Manager"]
    KGManager --> D14["Structured Triplet"] --> SQLite
    LLMManager --> D15["Inject All Facts"] --> AIModel

    %% Core styles
    classDef core fill:#0f172a,stroke:#7c3aed,color:#a78bfa
    classDef storage fill:#1e293b,stroke:#334155,color:#94a3b8

    class LLMManager,RAGManager,EmbedService,AIModel core
    class MemStore,Vector,SQLite storage

    %% Data flow style (consistent with your other diagrams)
    classDef data fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    class D1,D2,D3,D4,D5,D6,D7,D8,D9,D10,D11,D12 data
```

## Privacy

All memory data is stored **locally on-device**. Vector generation happens locally via Apple's built-in frameworks. No text or embeddings are sent to external servers for storage or processing (except for the context injected into cloud-based LLM prompts like OpenAI).

## Technical Details

- **Embedding Model**: `NLEmbedding.sentenceEmbedding(for: .english)`
- **Vector Dimension**: 512
- **Similarity Metric**: Cosine Similarity
- **Database**: SQLite3
- **File Limit Compliance**: Implemented using extensions and modular services to stay under the 500-line limit per file.
