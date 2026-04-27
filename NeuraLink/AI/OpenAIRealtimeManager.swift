//
//  OpenAIRealtimeManager.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import AVFoundation
import Foundation
import RealTimeCutVADLibrary
import SwiftUI
import WebRTC

/// Signature for handling incoming events from OpenAI
protocol OpenAIRealtimeDelegate: AnyObject {
    func openaiDidUpdateStatus(_ status: AIConnectionStatus)
    func openaiDidReceiveTranscript(_ text: String, isUser: Bool)
    func openaiDidUpdateAudioLevel(_ level: Float)
}

/// Core manager for OpenAI Realtime API via WebRTC.
final class OpenAIRealtimeManager: NSObject, @unchecked Sendable {
    static let shared = OpenAIRealtimeManager()

    private var peerConnection: RTCPeerConnection?
    private var remoteDataChannel: RTCDataChannel?
    private let factory: RTCPeerConnectionFactory
    private var statsTimer: Timer?
    private var pendingOffer: RTCSessionDescription?
    private var iceGatheringTimeout: Task<Void, Never>?
    private let sileroVAD = SileroVADProcessor()

    // Dependencies
    private let settings = OpenAISettings.shared
    private let state = RealtimeChatState.shared

    // Function-call state (one active call at a time)
    private var pendingFunctionCallId: String = ""
    private var pendingFunctionName: String = ""
    private var pendingFunctionArgsJSON: String = ""

    override init() {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setCategory(.playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
            try rtcSession.setMode(.videoChat)
            try rtcSession.setActive(true)
            rtcSession.isAudioEnabled = true
            print("[AI]: RTCAudioSession configured for speaker output")
        } catch {
            print("[AI]: Failed to configure RTCAudioSession: \(error)")
        }
        rtcSession.unlockForConfiguration()
    }

    private func forceAudioToSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            print("[AI]: Failed to override output port: \(error)")
        }
    }

    /// Starts the Realtime session
    func connect() {
        guard settings.hasValidKey else {
            state.setError("Invalid API Key")
            return
        }

        state.status = .connecting
        print("[AI]: Connecting to OpenAI Realtime...")
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.setupAudioSession()
            self?.setupPeerConnection()
            self?.createAndSendOffer()
        }
    }

    /// Stops the Realtime session
    func disconnect() {
        sileroVAD.stop()
        remoteDataChannel?.close()
        peerConnection?.close()
        peerConnection = nil
        stopStatsPolling()
        state.status = .disconnected
    }

    // MARK: - WebRTC Signaling

    private func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.iceCandidatePoolSize = 10

        // Add STUN servers to help with NAT traversal
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun3.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun4.l.google.com:19302"])
        ]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        self.peerConnection = factory.peerConnection(
            with: config, constraints: constraints, delegate: self)

        // Add Audio track
        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection?.add(audioTrack, streamIds: ["stream0"])

        // Setup Data Channel
        let dataChannelConfig = RTCDataChannelConfiguration()
        self.remoteDataChannel = peerConnection?.dataChannel(
            forLabel: "oai-events", configuration: dataChannelConfig)
        self.remoteDataChannel?.delegate = self
    }

    private func createAndSendOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
            ], optionalConstraints: nil)

        peerConnection?.offer(for: constraints) { [weak self] offer, error in
            print("[AI]: Creating SDP offer...")
            guard let self = self, let offer = offer else {
                self?.state.setError(
                    "Failed to create offer: \(error?.localizedDescription ?? "unknown")")
                return
            }

            self.peerConnection?.setLocalDescription(offer) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.state.setError("Failed to set local desc: \(error.localizedDescription)")
                    return
                }
                print("[AI]: SDP offer set, gathering ICE candidates (timeout in 1.5s)...")
                self.pendingOffer = offer

                // Fallback timeout: Send what we have if gathering takes too long
                self.iceGatheringTimeout?.cancel()
                self.iceGatheringTimeout = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        print("[AI]: ICE gathering timeout reached, sending available candidates")
                        self.sendOfferIfPossible()
                    }
                }
            }
        }
    }

    private func sendOfferIfPossible() {
        guard let offer = peerConnection?.localDescription, pendingOffer != nil else { return }
        iceGatheringTimeout?.cancel()
        iceGatheringTimeout = nil
        pendingOffer = nil  // Mark as sent
        sendOfferToOpenAI(offer)
    }

    private func sendOfferToOpenAI(_ offer: RTCSessionDescription) {
        let url = URL(
            string: "https://api.openai.com/v1/realtime?model=gpt-realtime")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.sdp.data(using: .utf8)

        print("[AI]: Sending SDP offer to OpenAI...")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }

            if let error = error {
                Task { @MainActor in
                    self.state.setError("Signaling error: \(error.localizedDescription)")
                }
                return
            }

            guard let data = data, let sdpAnswer = String(data: data, encoding: .utf8) else {
                Task { @MainActor in self.state.setError("Invalid SDP answer") }
                return
            }

            print("[AI]: Received answer length: \(sdpAnswer.count)")
            if sdpAnswer.contains("m=audio") {
                print("[AI]: Answer contains audio track")
            } else {
                print("[AI]: WARNING - Answer does NOT contain audio track")
            }

            let answer = RTCSessionDescription(type: .answer, sdp: sdpAnswer)
            print("[AI]: Received SDP answer from OpenAI")
            self.peerConnection?.setRemoteDescription(answer) { error in
                Task { @MainActor in
                    if let error = error {
                        self.state.setError(
                            "Failed to set remote desc: \(error.localizedDescription)")
                    } else {
                        print("[AI]: Connection established and ready")
                        self.state.status = .ready
                        self.forceAudioToSpeaker()
                        self.startStatsPolling()
                        self.startSileroVADIfEnabled()
                    }
                }
            }
        }.resume()
    }

    /// Polling stats to extract audio levels for lip-sync
    private func startStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] _ in
                self?.peerConnection?.statistics { report in
                    for (_, stats) in report.statistics {
                        if stats.type == "inbound-rtp",
                            let audioLevelValue = stats.values["audioLevel"] {
                            let level = (audioLevelValue as? NSNumber)?.floatValue ?? 0.0
                            if level > 0.01 {
                                print("[AI]: Incoming audio level detected: \(level)")
                            }
                            Task { @MainActor in
                                RealtimeChatState.shared.audioLevel = level
                            }
                        }
                    }
                }
            }
        }
    }

    /// Stops polling
    private func stopStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
        }
    }

    // MARK: - Message Handling

    private func handleIncomingJSON(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }

        Task { @MainActor in
            switch type {

            // ── Text streaming ────────────────────────────────────────────
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
                    pendingFunctionCallId   = item["call_id"] as? String ?? ""
                    pendingFunctionName     = item["name"]    as? String ?? ""
                    pendingFunctionArgsJSON = ""
                    print("[AI Tools]: function_call started — \(pendingFunctionName)")
                } else {
                    state.aiTranscript = ""
                    state.status = .speaking
                }

            // ── Function call argument streaming ─────────────────────────
            case "response.function_call_arguments.delta":
                if let delta = json["delta"] as? String {
                    pendingFunctionArgsJSON += delta
                }

            case "response.function_call_arguments.done":
                let callId   = pendingFunctionCallId
                let funcName = pendingFunctionName
                let argsJSON = pendingFunctionArgsJSON
                pendingFunctionCallId   = ""
                pendingFunctionName     = ""
                pendingFunctionArgsJSON = ""

                guard !funcName.isEmpty else { break }
                print("[AI Tools]: executing \(funcName) args=\(argsJSON)")

                // Parse args and execute
                let args = (try? JSONSerialization.jsonObject(
                    with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
                let result = await AppFunctionExecutor.shared.execute(
                    name: funcName, arguments: args)

                print("[AI Tools]: result → \(result)")
                sendFunctionResult(callId: callId, result: result)

            // ── Response lifecycle ────────────────────────────────────────
            case "response.done":
                state.status = .ready

            default:
                break
            }
        }
    }

    /// Sends a function_call_output item back to the AI and triggers a new response.
    private func sendFunctionResult(callId: String, result: String) {
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

    private func sendInitialSessionUpdate() {
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

extension OpenAIRealtimeManager {
    private func startSileroVADIfEnabled() {
        guard settings.isVADEnabled else { return }
        sileroVAD.delegate = self
        sileroVAD.start()
    }
}

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
