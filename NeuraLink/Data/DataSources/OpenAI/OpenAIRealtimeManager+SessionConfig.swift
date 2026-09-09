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

    func sendInitialSessionUpdate() {
        Task {
            let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)

            // RAG: Fetch relevant memories for the current persona/session
            // Since we don't have a specific query yet, we fetch general recent context
            // or just the persona-related memories. For now, we'll fetch context
            // based on the character's core identity to ground the session.
            let userContext = UserSettings.shared.systemPromptContext
            let memoryContext = await RAGManager.shared.fetchContext(
                for: persona.instructions, limit: 5)
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
                """

            let finalInstructions =
                persona.instructions + "\n"
                + userContext + memoryContext + kgFacts + companion
                + factsTriggerInstruction

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
                                "model": "gpt-4o-transcribe",
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

            guard let data = try? JSONSerialization.data(withJSONObject: update) else { return }

            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
            nlLog(
                "[AI]: Sent initial session.update with \(AppFunctionTool.all.count) tools and instructions: \(finalInstructions.prefix(100))...",
                level: .info)
        }
    }
}
