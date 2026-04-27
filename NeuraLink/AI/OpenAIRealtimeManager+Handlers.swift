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

            // Text streaming
            case "response.audio_transcript.delta":
                if let delta = json["delta"] as? String {
                    print("[AI Text Delta]: \(delta)")
                    state.aiTranscript += delta
                }

            case "conversation.item.input_audio_transcription.completed":
                if let transcript = json["transcript"] as? String {
                    print("[User Transcript]: \(transcript)")
                    state.userTranscript = transcript
                }

            case "response.output_item.added":
                if let item = json["item"] as? [String: Any],
                    let itemType = item["type"] as? String,
                    itemType == "function_call" {
                    // Begin accumulating a function call
                    pendingFunctionCallId = item["call_id"] as? String ?? ""
                    pendingFunctionName = item["name"] as? String ?? ""
                    pendingFunctionArgsJSON = ""
                    print("[AI Tools]: function_call started — \(pendingFunctionName)")
                } else {
                    state.aiTranscript = ""
                    state.status = .speaking
                    speakingStartTime = Date()
                    transcriptDoneTime = nil
                }

            // Fired when all transcript text for this response has been received.
            // In real-time streaming this timestamp closely tracks actual audio completion.
            case "response.audio_transcript.done":
                transcriptDoneTime = Date()
                print("[AI Tools]: transcript done at \(Date())")

            // Function call argument streaming
            case "response.function_call_arguments.delta":
                if let delta = json["delta"] as? String {
                    pendingFunctionArgsJSON += delta
                }

            case "response.function_call_arguments.done":
                if !pendingFunctionName.isEmpty {
                    deferredFunctionCall = (
                        id: pendingFunctionCallId,
                        name: pendingFunctionName,
                        args: pendingFunctionArgsJSON
                    )
                    print(
                        "[AI Tools]: Arguments complete for \(pendingFunctionName). Deferring execution until response.done"
                    )
                }
                pendingFunctionCallId = ""
                pendingFunctionName = ""
                pendingFunctionArgsJSON = ""

            // Response lifecycle
            case "response.done":
                state.status = .ready
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
                    print("[AI Tools]: result → \(result)")
                    sendFunctionResult(callId: deferred.id, result: result)
                } else if AppFunctionExecutor.shared.pendingUIAction != nil {
                    // The AI just finished speaking the result of a previous function call.
                    // Wait for this audio to finish, then fire the deferred app-open.
                    schedulePendingUIAction()
                }

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
                let targetA = start.addingTimeInterval(estimatedDuration + 0.5)
                let targetB = doneTime?.addingTimeInterval(0.5) ?? .distantPast
                let target = max(targetA, targetB)
                let remaining = target.timeIntervalSinceNow
                if remaining > 0 {
                    print(
                        "[AI Tools]: Waiting \(String(format: "%.2f", remaining))s for audio before opening app"
                    )
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            }

            let action = AppFunctionExecutor.shared.pendingUIAction
            AppFunctionExecutor.shared.pendingUIAction = nil
            action?()
            print("[AI Tools]: App opened after audio finished")
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
        print("[AI Tools]: sent function_call_output for call_id=\(callId)")
    }
}

// MARK: - RTCPeerConnectionDelegate

extension OpenAIRealtimeManager: RTCPeerConnectionDelegate {
    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState
    ) {
        print("[AI]: Signaling state changed: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("[AI]: Stream added with \(stream.audioTracks.count) audio tracks")
        for track in stream.audioTracks {
            track.isEnabled = true
            print("[AI]: Audio track \(track.trackId) enabled")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("[AI]: Stream removed")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("[AI]: PeerConnection should negotiate")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState
    ) {
        print("[AI]: ICE connection state changed: \(newState.rawValue)")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState
    ) {
        print("[AI]: ICE gathering state changed: \(newState.rawValue)")
        if newState == .complete {
            print("[AI]: ICE gathering complete via delegate")
            sendOfferIfPossible()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("[AI]: Generated ICE candidate: \(candidate.sdpMid ?? "none")")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]
    ) {
        print("[AI]: Removed ICE candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("[AI]: Data channel opened")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
    ) {
        print("[AI]: PeerConnection state changed: \(newState.rawValue)")
    }

    func peerConnection(
        _ peerConnection: RTCPeerConnection, didStartReceiver receiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        let kind = receiver.track?.kind ?? "unknown"
        print("[AI]: Started receiver for \(kind) track")
        if let audioTrack = receiver.track as? RTCAudioTrack {
            audioTrack.isEnabled = true
            print("[AI]: Remote audio track enabled: \(audioTrack.trackId)")
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
        print("[AI]: Data channel state changed: \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            print("[AI]: Data channel is officially OPEN")
            sendInitialSessionUpdate()
        }
    }

    func sendInitialSessionUpdate() {
        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": persona.voice,
                "instructions": persona.instructions,
                "tools": AppFunctionTool.all,
                "tool_choice": "auto",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad"
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: update) else { return }

        let buffer = RTCDataBuffer(data: data, isBinary: false)
        remoteDataChannel?.sendData(buffer)
        print("[AI]: Sent initial session.update with \(AppFunctionTool.all.count) tools")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let data = String(data: buffer.data, encoding: .utf8)?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let type = json["type"] as? String {
            print("[AI Event Received]: \(type)")
        }

        handleIncomingJSON(json)
    }
}

// MARK: - Silero VAD

extension OpenAIRealtimeManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        guard state.status == .ready else { return }
        state.status = .listening
        print("[SileroVAD]: Voice detected → listening")
    }

    func sileroVADDidDetectVoiceEnd() {
        guard state.status == .listening else { return }
        state.status = .ready
        print("[SileroVAD]: Voice ended → ready")
    }
}
