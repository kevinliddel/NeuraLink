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
            nlLog("[AI]: RTCAudioSession configured for speaker output", level: .info)
        } catch {
            nlLog("[AI]: Failed to configure RTCAudioSession: \(error)", level: .error)
        }
        rtcSession.unlockForConfiguration()
    }

    func forceAudioToSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            nlLog("[AI]: Failed to override output port: \(error)", level: .error)
        }
    }

    /// Starts the Realtime session
    func connect() {
        guard settings.hasValidKey else {
            state.setError("Invalid API Key")
            return
        }
        
        // Prevent redundant connection attempts if already active or connecting.
        guard state.status != .connecting && state.status != .ready && state.status != .speaking && state.status != .thinking else {
            nlLog("[AI]: Already connected or connecting, skipping.", level: .info)
            return
        }

        state.status = .connecting
        nlLog("[AI]: Connecting to OpenAI Realtime...", level: .info)
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
        ProactiveVisionManager.shared.stop()
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
            nlLog("[AI]: Creating SDP offer...", level: .info)
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
                nlLog("[AI]: SDP offer set, gathering ICE candidates (timeout in 1.5s)...", level: .info)
                self.pendingOffer = offer

                // Fallback timeout: Send what we have if gathering takes too long
                self.iceGatheringTimeout?.cancel()
                self.iceGatheringTimeout = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        nlLog("[AI]: ICE gathering timeout reached, sending available candidates", level: .info)
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
        // GA two-step handshake (replaces the deprecated direct-key SDP POST,
        // which now returns `beta_api_shape_disabled`):
        //   1. POST /v1/realtime/client_secrets with master API key →
        //      JSON body containing `client_secret.value` (an ephemeral
        //      token valid for ~1 minute).
        //   2. POST /v1/realtime?model=... with the ephemeral token as
        //      Bearer auth and the SDP offer body.
        // The master API key is therefore the only thing that touches
        // the auth endpoint; the SDP POST uses the short-lived secret.
        requestEphemeralKey { [weak self] ephemeralKey, errorMessage in
            guard let self = self else { return }
            if let key = ephemeralKey {
                self.postSDPOffer(offer, ephemeralKey: key)
            } else {
                Task { @MainActor in
                    self.state.setError(errorMessage ?? "Unknown error minting ephemeral key")
                }
            }
        }
    }

    /// Step 1 of the GA handshake: mint a short-lived ephemeral key. The
    /// completion fires on URLSession's background queue. On success the
    /// `key` argument holds the ephemeral token; on failure it's nil and
    /// `error` holds a human-readable message. Two-arg shape instead of
    /// `Result<String, Error>` avoids needing a wrapper error type for
    /// what is purely string-shaped diagnostics.
    private func requestEphemeralKey(
        completion: @escaping (_ key: String?, _ error: String?) -> Void
    ) {
        let url = URL(
            string: "https://api.openai.com/v1/realtime/client_secrets")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "session": [
                "type": "realtime",
                "model": "gpt-realtime"
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        nlLog("[AI]: Minting ephemeral key (client_secrets)...", level: .info)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, "Ephemeral key network error: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data = data else {
                completion(nil, "Ephemeral key: empty response (HTTP \(status))")
                return
            }
            // Expected shape — `client_secret.value` holds the token. Some
            // older API variants return `value` at the top level instead;
            // accept both so we don't break if OpenAI changes the wrapper.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let inner = json["client_secret"] as? [String: Any],
                   let value = inner["value"] as? String, !value.isEmpty {
                    nlLog("[AI]: Ephemeral key minted (status=\(status))", level: .info)
                    completion(value, nil)
                    return
                }
                if let value = json["value"] as? String, !value.isEmpty {
                    nlLog("[AI]: Ephemeral key minted (status=\(status), top-level shape)", level: .info)
                    completion(value, nil)
                    return
                }
            }
            // No usable token in the body — surface the raw payload so the
            // user can read the actual reason (invalid key, model mismatch,
            // org quota, etc).
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            nlLog("[AI]: client_secrets failed (status=\(status)): \(preview)", level: .warning)
            completion(nil, "OpenAI client_secrets HTTP \(status): \(preview.prefix(180))")
        }.resume()
    }

    /// Step 2 of the GA handshake: POST the SDP offer to `/v1/realtime/calls`
    /// (the GA WebRTC endpoint — the old `/v1/realtime` path returns
    /// `beta_api_shape_disabled`). Authentication uses the ephemeral key
    /// minted in step 1; the master API key never touches this endpoint.
    /// The model isn't passed in the URL anymore — it's already fixed by
    /// the session config sent to `/client_secrets` above.
    private func postSDPOffer(_ offer: RTCSessionDescription, ephemeralKey: String) {
        let url = URL(
            string: "https://api.openai.com/v1/realtime/calls")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.sdp.data(using: .utf8)

        nlLog("[AI]: Sending SDP offer to OpenAI...", level: .info)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let contentType = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            nlLog("[AI]: Received answer length: \(sdpAnswer.count) status=\(httpStatus) content-type=\(contentType)", level: .info)
            if !sdpAnswer.hasPrefix("v=0") {
                let preview = String(sdpAnswer.prefix(500))
                nlLog("[AI]: Non-SDP body (likely an error): \(preview)", level: .warning)
                Task { @MainActor in
                    self.state.setError("OpenAI returned HTTP \(httpStatus) instead of SDP. Body preview: \(preview.prefix(120))")
                }
                return
            }
            if sdpAnswer.contains("m=audio") {
                nlLog("[AI]: Answer contains audio track", level: .info)
            } else {
                nlLog("[AI]: WARNING - Answer does NOT contain audio track", level: .warning)
            }

            let answer = RTCSessionDescription(type: .answer, sdp: sdpAnswer)
            nlLog("[AI]: Received SDP answer from OpenAI", level: .info)
            self.peerConnection?.setRemoteDescription(answer) { error in
                Task { @MainActor in
                    if let error = error {
                        self.state.setError(
                            "Failed to set remote desc: \(error.localizedDescription)")
                    } else {
                        nlLog("[AI]: Connection established and ready", level: .info)
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
                                nlLog("[AI]: Incoming audio level detected: \(level)", level: .info)
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
