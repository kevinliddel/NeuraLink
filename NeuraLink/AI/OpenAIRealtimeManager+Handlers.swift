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
                }

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
                    deferredFunctionCall = nil
                    print(
                        "[AI Tools]: response.done — waiting for audio to finish before executing \(deferred.name)"
                    )
                    schedulePostAudioExecution(deferred)
                }

            default:
                break
            }
        }
    }

    /// Waits for the AI's spoken audio to finish, then executes the function call.
    /// Polls audioLevel every 50 ms; adds a 400 ms drain delay once silence is detected.
    func schedulePostAudioExecution(_ call: (id: String, name: String, args: String)) {
        audioPlaybackMonitorTask?.cancel()
        audioPlaybackMonitorTask = Task { @MainActor in
            // Allow up to 500 ms for audio to start (the AI may begin speaking slightly after response.done)
            var audioSeen = state.audioLevel > 0.01
            if !audioSeen {
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { return }
                    if state.audioLevel > 0.01 {
                        audioSeen = true
                        break
                    }
                }
            }

            // Wait for the audio to drop back to silence
            if audioSeen {
                while state.audioLevel > 0.01 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { return }
                }
                // Extra delay to let the WebRTC playout buffer fully drain
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
            }

            print("[AI Tools]: Audio finished. Executing \(call.name)")
            let args =
                (try? JSONSerialization.jsonObject(with: Data(call.args.utf8)) as? [String: Any]) ?? [:]
            let result = await AppFunctionExecutor.shared.execute(name: call.name, arguments: args)
            print("[AI Tools]: result → \(result)")
            sendFunctionResult(callId: call.id, result: result)
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
