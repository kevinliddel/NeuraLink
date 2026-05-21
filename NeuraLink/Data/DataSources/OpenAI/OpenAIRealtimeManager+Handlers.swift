//
//  OpenAIRealtimeManager+Handlers.swift
//  NeuraLink
//
//  Extension for handling incoming WebRTC data channel events,
//  function calling, and protocol conformances.
//

import Foundation
import WebRTC

// MARK: - Message Handling

extension OpenAIRealtimeManager {

    func handleIncomingJSON(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        Task { @MainActor in
            switch type {

            // GA event name. Beta variant was `response.audio_transcript.delta`
            // — see https://developers.openai.com/api/docs/guides/realtime
            // §"Beta to GA migration". If you ever see no transcript on a
            // working audio connection, OpenAI rotated the name again and
            // this case needs another rename.
            case "response.output_audio_transcript.delta":
                if let delta = json["delta"] as? String {
                    nlLog("[AI Text Delta]: \(delta)", level: .info)
                    state.aiTranscript += delta
                }

            case "conversation.item.input_audio_transcription.completed":
                if let transcript = json["transcript"] as? String {
                    nlLog("[User Transcript]: \(transcript)", level: .info)
                    state.userTranscript = transcript
                    ProactiveVisionManager.shared.notifyUserSpoke()
                    // RAG: Store user input in long-term memory
                    RAGManager.shared.store(text: transcript, source: "user")
                    ChatTimelineStore.logUserMessage(transcript)
                }

            case "response.output_item.added":
                if let item = json["item"] as? [String: Any],
                    let itemType = item["type"] as? String,
                    itemType == "function_call" {
                    // Begin accumulating a function call
                    pendingFunctionCallId = item["call_id"] as? String ?? ""
                    pendingFunctionName = item["name"] as? String ?? ""
                    pendingFunctionArgsJSON = ""
                    nlLog("[AI Tools]: function_call started — \(pendingFunctionName)", level: .info)
                } else {
                    state.aiTranscript = ""
                    state.status = .speaking
                    speakingStartTime = Date()
                    transcriptDoneTime = nil
                }

            // Fired when all transcript text for this response has been received.
            // In real-time streaming this timestamp closely tracks actual audio completion.
            // GA event name — see the `.delta` case above for context.
            case "response.output_audio_transcript.done":
                transcriptDoneTime = Date()
                nlLog("[AI Tools]: transcript done at \(Date())", level: .info)

            // Function call argument streaming
            case "response.function_call_arguments.delta":
                if let delta = json["delta"] as? String {
                    pendingFunctionArgsJSON += delta
                }

            case "response.function_call_arguments.done":
                if pendingFunctionName == AppFunctionTool.setEmotion {
                    // Handle immediately — no deferral, no audio interruption.
                    // The model calls this before speaking, so the face updates
                    // before audio starts. Sending the result + response.create
                    // continues the conversation into the spoken audio response.
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(pendingFunctionArgsJSON.utf8)) as? [String: Any]) ?? [:]
                    if let emotion = args["emotion"] as? String,
                       let duration = args["duration"] as? Double {
                        state.triggerEmotion(emotion, duration: Float(duration))
                        nlLog("[Emotion] \(emotion) for \(duration)s", level: .info)
                    }
                    sendFunctionResult(callId: pendingFunctionCallId, result: "ok")
                } else if !pendingFunctionName.isEmpty {
                    deferredFunctionCall = (
                        id: pendingFunctionCallId,
                        name: pendingFunctionName,
                        args: pendingFunctionArgsJSON
                    )
                    nlLog(
                        "[AI Tools]: Arguments complete for \(pendingFunctionName). Deferring execution until response.done",
                        level: .info)
                }
                pendingFunctionCallId = ""
                pendingFunctionName = ""
                pendingFunctionArgsJSON = ""

            // Response lifecycle
            case "response.done":
                nlLog("[OpenAI] Full response: \(state.aiTranscript)", level: .info)
                state.status = .ready
                
                // RAG: Store AI response in long-term memory
                RAGManager.shared.store(text: state.aiTranscript, source: "ai")
                ChatTimelineStore.logAIMessage(state.aiTranscript)

                if let deferred = deferredFunctionCall {
                    // Execute the function immediately — for UI-opening functions
                    // (playMusic, searchWeb, openApp, openNotes) AppFunctionExecutor stores
                    // the open() call in pendingUIAction instead of firing it here.
                    // That action will be triggered after the AI finishes speaking the result.
                    deferredFunctionCall = nil
                    let args =
                        (try? JSONSerialization.jsonObject(
                            with: Data(deferred.args.utf8)) as? [String: Any]) ?? [:]
                    let result = await AppFunctionExecutor.shared.execute(
                        name: deferred.name, arguments: args)
                    nlLog("[AI Tools]: result → \(result)", level: .info)
                    ChatTimelineStore.logToolCall(name: deferred.name, result: result)
                    sendFunctionResult(callId: deferred.id, result: result)
                } else if AppFunctionExecutor.shared.pendingUIAction != nil {
                    // The AI just finished speaking the result of a previous function call.
                    // Wait for this audio to finish, then fire the deferred app-open.
                    schedulePendingUIAction()
                }

            // Surface server-side errors verbatim. Without this, a rejected
            // session.update (wrong field name, invalid value, etc.) was
            // failing silently — the model would then run with vanilla
            // defaults, ignoring our persona/language/context instructions.
            // Symptom report that led to this: "model used to speak Japanese
            // per the persona, now speaks English" + "user context and
            // date/time aren't applied". Both fit a dropped session.update.
            case "error":
                let preview = (try? JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted]))
                    .flatMap { String(data: $0, encoding: .utf8) }?.prefix(800) ?? ""
                nlLog("[AI ERROR EVENT]: \(preview)", level: .warning)

            // Server ack that the session.update we sent was accepted. If we
            // sent one but never see this, the body had a schema problem.
            case "session.updated", "session.created":
                let sess = (json["session"] as? [String: Any]) ?? [:]
                let instr = (sess["instructions"] as? String) ?? "(none)"
                let voice = ((sess["audio"] as? [String: Any])?["output"] as? [String: Any])?["voice"] as? String ?? "(default)"
                nlLog("[AI \(type)]: voice=\(voice) instructions=\"\(instr)…\"", level: .info)

            default:
                break
            }
        }
    }

    /// Waits for the AI's spoken audio to finish, then fires `AppFunctionExecutor.pendingUIAction`.
    ///
    /// Called at `response.done` when there is no function call but a UI action is pending —
    /// meaning the AI just finished speaking the result of a previous function call.
    ///
    /// Two signals combined, taking the later:
    ///   A) speakingStartTime + (chars / 15) + 0.5 s  — duration estimate anchored to when
    ///      the AI started speaking (works whether audio was burst-sent or streamed in real-time)
    ///   B) transcriptDoneTime + 0.5 s  — closely tracks audio completion in real-time streaming
    func schedulePendingUIAction() {
        audioPlaybackMonitorTask?.cancel()

        let startTime = speakingStartTime
        let doneTime = transcriptDoneTime
        let charCount = state.aiTranscript.count

        speakingStartTime = nil
        transcriptDoneTime = nil

        audioPlaybackMonitorTask = Task { @MainActor in
            if let start = startTime {
                let estimatedDuration = max(Double(charCount) / 15.0, 1.0)
                let targetA = start.addingTimeInterval(estimatedDuration + 1.5)
                let targetB = doneTime?.addingTimeInterval(1.5) ?? .distantPast
                let target = max(targetA, targetB)
                let remaining = target.timeIntervalSinceNow
                if remaining > 0 {
                    nlLog(
                        "[AI Tools]: Waiting \(String(format: "%.2f", remaining))s for audio before opening app",
                        level: .info)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }

            let action = AppFunctionExecutor.shared.pendingUIAction
            AppFunctionExecutor.shared.pendingUIAction = nil
            action?()
            nlLog("[AI Tools]: App opened after audio finished", level: .info)
        }
    }

    /// Sends a function_call_output item back to the AI and triggers a new response.
    func sendFunctionResult(callId: String, result: String) {
        let output: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ]
        ]
        let trigger: [String: Any] = ["type": "response.create"]

        for payload in [output, trigger] {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
        }
        nlLog("[AI Tools]: sent function_call_output for call_id=\(callId)", level: .info)
    }
    /// Sends a proactive vision update as a system message to the AI.
    func sendProactiveVisionUpdate(description: String) {
        let content = "[Vision Update: \(description)]"
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    ["type": "input_text", "text": content]
                ]
            ]
        ]
        let trigger: [String: Any] = ["type": "response.create"]

        for payload in [item, trigger] {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
        }
        nlLog("[AI Vision]: sent proactive update: \(description.prefix(50))...", level: .info)
    }

    /// Sends a physical interaction event (e.g. head pat) to the AI.
    func sendInteractionEvent(_ action: String) {
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    ["type": "input_text", "text": action]
                ]
            ]
        ]
        let trigger: [String: Any] = ["type": "response.create"]

        for payload in [item, trigger] {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
        }
        nlLog("[AI Interaction]: sent event: \(action)", level: .info)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension OpenAIRealtimeManager: RTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {
        nlLog("[AI]: Signaling state changed: \(stateChanged.rawValue)", level: .info)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        nlLog("[AI]: Stream added with \(stream.audioTracks.count) audio tracks", level: .info)
        for track in stream.audioTracks {
            track.isEnabled = true
            nlLog("[AI]: Audio track \(track.trackId) enabled", level: .info)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        nlLog("[AI]: Stream removed", level: .info)
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        nlLog("[AI]: PeerConnection should negotiate", level: .info)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {
        nlLog("[AI]: ICE connection state changed: \(newState.rawValue)", level: .info)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
    ) {
        nlLog("[AI]: ICE gathering state changed: \(newState.rawValue)", level: .info)
        if newState == .complete {
            nlLog("[AI]: ICE gathering complete via delegate", level: .info)
            sendOfferIfPossible()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        nlLog("[AI]: Generated ICE candidate: \(candidate.sdpMid ?? "none")", level: .info)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
    ) {
        nlLog("[AI]: Removed ICE candidates", level: .info)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        nlLog("[AI]: Data channel opened", level: .info)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
    ) {
        nlLog("[AI]: PeerConnection state changed: \(newState.rawValue)", level: .info)
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didStartReceiver receiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        let kind = receiver.track?.kind ?? "unknown"
        nlLog("[AI]: Started receiver for \(kind) track", level: .info)
        if let audioTrack = receiver.track as? RTCAudioTrack {
            audioTrack.isEnabled = true
            nlLog("[AI]: Remote audio track enabled: \(audioTrack.trackId)", level: .info)
            let rtcSession = RTCAudioSession.sharedInstance()
            rtcSession.lockForConfiguration()
            try? rtcSession.setActive(true)
            rtcSession.isAudioEnabled = true
            rtcSession.unlockForConfiguration()
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension OpenAIRealtimeManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        nlLog("[AI]: Data channel state changed: \(dataChannel.readyState.rawValue)", level: .info)
        if dataChannel.readyState == .open {
            nlLog("[AI]: Data channel is officially OPEN", level: .info)
            sendInitialSessionUpdate()
            ProactiveVisionManager.shared.start()
        }
    }

    func sendInitialSessionUpdate() {
        Task {
            let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
            
            // RAG: Fetch relevant memories for the current persona/session
            // Since we don't have a specific query yet, we fetch general recent context
            // or just the persona-related memories. For now, we'll fetch context
            // based on the character's core identity to ground the session.
            let userContext = UserSettings.shared.systemPromptContext
            let memoryContext = await RAGManager.shared.fetchContext(for: persona.instructions, limit: 5)
            let kgFacts = KnowledgeGraphManager.shared.getFormattedFacts()
            let companion = CompanionStateManager.shared.promptContext(characterName: state.selectedCharacterName)
            let finalInstructions = persona.instructions + "\n" + userContext + memoryContext + kgFacts + companion
            
            // GA session shape. Key differences from the beta body:
            //   - `session.type = "realtime"` is now required (was implicit).
            //   - `modalities` → `output_modalities` (same semantics).
            //   - `voice` moved under `session.audio.output`.
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
                    // (see §4 of docs/openai_realtime_ga_migration.md).
                    "output_modalities": ["audio"],
                    "instructions": finalInstructions,
                    "tools": AppFunctionTool.all,
                    "tool_choice": "auto",
                    "audio": [
                        "input": [
                            "transcription": [
                                "model": "whisper-1"
                            ],
                            "turn_detection": [
                                "type": "server_vad"
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
                        ],
                        "output": [
                            "voice": persona.voice
                        ]
                    ]
                ]
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: update) else { return }

            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
            nlLog("[AI]: Sent initial session.update with \(AppFunctionTool.all.count) tools and instructions: \(finalInstructions.prefix(100))...", level: .info)
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let data = String(data: buffer.data, encoding: .utf8)?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let type = json["type"] as? String {
            nlLog("[AI Event Received]: \(type)", level: .info)
        }

        handleIncomingJSON(json)
    }
}

// MARK: - Silero VAD

extension OpenAIRealtimeManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        guard state.status == .ready else { return }
        state.status = .listening
        nlLog("[SileroVAD]: Voice detected → listening", level: .info)
    }

    func sileroVADDidDetectVoiceEnd(wavData: Data?) {
        guard state.status == .listening else { return }
        state.status = .ready
        nlLog("[SileroVAD]: Voice ended → ready", level: .info)
    }
}
