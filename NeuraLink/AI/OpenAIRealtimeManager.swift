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

    var peerConnection: RTCPeerConnection?
    var remoteDataChannel: RTCDataChannel?
    let factory: RTCPeerConnectionFactory
    private var statsTimer: Timer?
    var pendingOffer: RTCSessionDescription?
    var iceGatheringTimeout: Task<Void, Never>?
    let sileroVAD = SileroVADProcessor()

    // Dependencies
    let settings = OpenAISettings.shared
    let state = RealtimeChatState.shared

    // Function-call state (one active call at a time)
    var pendingFunctionCallId: String = ""
    var pendingFunctionName: String = ""
    var pendingFunctionArgsJSON: String = ""
    var deferredFunctionCall: (id: String, name: String, args: String)?

    // Post-audio execution: function waits until the AI's spoken audio finishes
    var audioPlaybackMonitorTask: Task<Void, Never>?
    // Set when the audio output item starts; anchors the speaking-duration estimate
    var speakingStartTime: Date?
    // Set when response.audio_transcript.done fires (real-time streaming signal)
    var transcriptDoneTime: Date?

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
            try rtcSession.setCategory(
                .playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
            try rtcSession.setMode(.videoChat)
            try rtcSession.setActive(true)
            rtcSession.isAudioEnabled = true
            print("[AI]: RTCAudioSession configured for speaker output")
        } catch {
            print("[AI]: Failed to configure RTCAudioSession: \(error)")
        }
        rtcSession.unlockForConfiguration()
    }

    func forceAudioToSpeaker() {
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
        audioPlaybackMonitorTask?.cancel()
        audioPlaybackMonitorTask = nil
        speakingStartTime = nil
        transcriptDoneTime = nil
        AppFunctionExecutor.shared.pendingUIAction = nil
        sileroVAD.stop()
        remoteDataChannel?.close()
        peerConnection?.close()
        peerConnection = nil
        stopStatsPolling()
        state.status = .disconnected
    }

    // MARK: - WebRTC Signaling

    func setupPeerConnection() {
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

    func createAndSendOffer() {
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

    func sendOfferIfPossible() {
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
    func startStatsPolling() {
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
    func stopStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
        }
    }

    // MARK: - Silero VAD

    func startSileroVADIfEnabled() {
        guard settings.isVADEnabled else { return }
        sileroVAD.delegate = self
        sileroVAD.start()
    }
}
