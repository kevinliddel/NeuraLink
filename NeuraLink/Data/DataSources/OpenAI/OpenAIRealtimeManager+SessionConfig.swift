//
//  OpenAIRealtimeManager+SessionConfig.swift
//  NeuraLink
//
//  Builds and sends the initial GA `session.update` (instructions, tools,
//  transcription, VAD, noise reduction). Split from +Handlers for the
//  SwiftLint 495-line limit — this is the session's configuration story,
//  the delegate/event plumbing stays in +Handlers.
//

import Foundation
import WebRTC

extension OpenAIRealtimeManager {

    /// Recall query used to ground a fresh session before the user has said
    /// anything. A stable "about the user" query beats the persona text,
    /// whose vocabulary would steer keyword/semantic recall toward the
    /// character rather than the person.
    static let sessionGroundingQuery =
        "important facts about the user: their name, life, family, friends, pets, work, preferences and plans"

    /// Assembles the full system instructions: persona, user profile, mental
    /// models, recalled memories, knowledge-graph facts, companion state and
    /// the tool-usage rules. Shared by the initial `session.update` and the
    /// mid-session refresh (`+SessionRefresh.swift`).
    func buildSessionInstructions() async -> String {
        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)

        // RAG: Fetch relevant memories for the current persona/session
        // Since we don't have a specific query yet, we fetch general recent context
        // or just the persona-related memories. For now, we'll fetch context
        // based on the character's core identity to ground the session.
        let userContext = UserSettings.shared.systemPromptContext
        // Agentic memory: mental models are a zero-LLM DB read that
        // summarise the user + relationship; the recall block grounds
        // the session with the most relevant observations/facts. Mid-
        // session lookups go through the `search_memory` tool.
        let mentalModels = MemoryMentalModels.shared.promptBlock(
            character: state.selectedCharacterName)
        let memoryContext = await RAGManager.shared.fetchContext(
            for: Self.sessionGroundingQuery, limit: 5, tokenBudget: 500)
        let kgFacts = KnowledgeGraphManager.shared.getFormattedFacts()
        let companion = CompanionStateManager.shared.promptContext(
            characterName: state.selectedCharacterName)

        // Heavy personas (Ekaterina/Sonya) consume the model's attention
        // budget on character behaviour and de-prioritise tool calls. This
        // block restores the pre-security `remember_fact` autonomy by
        // making the trigger condition explicit and giving the model the
        // exact S/P/O shape to emit. Mirrors the local-LLM prompt's
        // explicit tool instructions.
        let factsTriggerInstruction = """

            TOOL USAGE — remember_fact:
              Whenever the user reveals a personal detail about themselves or \
              their life (name, family member, pet, job, hobby, preference, \
              location, relationship, dislike, etc.), call the `remember_fact` \
              function in addition to your spoken reply. Use S/P/O shape:
                subject  = "User" (or the named entity, e.g. the sister's name)
                predicate = the relationship (e.g. "has_sister", "likes", "lives_in")
                object   = the value (e.g. "Manohy", "sushi", "Tokyo")
              Do not announce the call in speech; just emit it silently.

            TOOL USAGE — search_memory:
              Before answering anything that depends on past conversations \
              (a person, place, plan or preference you may have heard before, \
              "remember when…", "what did I tell you about…"), call \
              `search_memory` with a short natural-language query and answer \
              from the results. If it returns nothing, say you don't recall.
            """

        return persona.instructions + "\n"
            + userContext + mentalModels + memoryContext + kgFacts + companion
            + factsTriggerInstruction
    }

    func sendInitialSessionUpdate() {
        Task {
            let finalInstructions = await buildSessionInstructions()

            // GA session shape. Key differences from the beta body:
            //   - `session.type = "realtime"` is now required (was implicit).
            //   - `modalities` → `output_modalities` (same semantics).
            //   - `voice` moved under `session.audio.output` — set ONCE at
            //     `/client_secrets` mint time (see `requestEphemeralKey`).
            //     Sending it again here triggers `cannot_update_voice` once
            //     any assistant audio is in flight, which drops the whole
            //     envelope on the floor.
            //   - `input_audio_transcription` → `session.audio.input.transcription`.
            //   - `turn_detection` moved under `session.audio.input`.
            // See https://developers.openai.com/api/docs/guides/realtime
            // §"Beta to GA migration" — the full migration enumerated there.
            let update: [String: Any] = [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    // GA only accepts ["text"] OR ["audio"] — not both. The
                    // beta `modalities: ["text", "audio"]` shape returns
                    // `invalid_value` at this key. Audio is what we want;
                    // the transcript still streams via
                    // `response.output_audio_transcript.delta` regardless
                    "output_modalities": ["audio"],
                    "instructions": finalInstructions,
                    "tools": AppFunctionTool.all,
                    "tool_choice": "auto",
                    "audio": [
                        "input": [
                            // The model understands the RAW AUDIO — this side-channel
                            // only produces the chat-history text. whisper-1 butchered
                            // proper nouns ("Unexplored Blood Sign" → "export PlotSign")
                            // while the AI acted correctly; gpt-4o-transcribe is far
                            // better on names/titles. Prompt biases vocabulary; no
                            // `language` pin so JP personas keep auto-detect.
                            "transcription": [
                                "model": settings.transcriptionModel,
                                "prompt": "Casual voice chat with an AI companion. May include "
                                    + "proper nouns: media/game/anime/song titles, app names, Japanese words."
                            ],
                            // Defaults (threshold 0.5, silence 500ms) are
                            // too trigger-happy for speaker-on use: room
                            // noise and echo residue were opening phantom
                            // user turns, which Whisper then "transcribed"
                            // into words the user never said. Higher
                            // threshold = needs louder/closer speech;
                            // longer silence window = fewer mid-pause cuts.
                            "turn_detection": [
                                "type": "server_vad",
                                "threshold": 0.75,
                                "prefix_padding_ms": 300,
                                "silence_duration_ms": 700
                            ],
                            // Server-side noise reduction on the user's mic
                            // input. `near_field` is calibrated for
                            // close-talk mics (phone held to mouth /
                            // earbuds); `far_field` is for room-distance
                            // mics. iPhone in conversational use is
                            // close-talk. Independent of the local LLM
                            // path's VPIO — applies only to audio that
                            // OpenAI receives over WebRTC.
                            "noise_reduction": [
                                "type": "near_field"
                            ]
                        ]
                    ]
                ]
            ]

            send(update)
            nlLog(
                "[AI]: Sent initial session.update with \(AppFunctionTool.all.count) tools and instructions: \(finalInstructions.prefix(100))...",
                level: .info)
        }
    }
}
