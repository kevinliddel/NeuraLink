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
import LiveKitWebRTC

/// Core manager for OpenAI Realtime API via WebRTC.
final class OpenAIRealtimeManager: NSObject, @unchecked Sendable {
    static let shared = OpenAIRealtimeManager()

    var peerConnection: LKRTCPeerConnection?
    /// The outgoing (mic) track — kept so song recognition can gate it.
    var localAudioTrack: LKRTCAudioTrack?
    var remoteDataChannel: LKRTCDataChannel?
    let factory: LKRTCPeerConnectionFactory
    /// Hears the remote audio track for the mouth (attached in `didStartReceiver`).
    let lipSync = RealtimeLipSyncRenderer()
    var pendingOffer: LKRTCSessionDescription?
    var iceGatheringTimeout: Task<Void, Never>?
    let sileroVAD = SileroVADProcessor()

    // Reconnect state (see +Reconnect.swift)
    var reconnectAttempt = 0
    var reconnectTask: Task<Void, Never>?
    var iceGraceTask: Task<Void, Never>?
    var isReconnecting = false
    /// Set by `disconnect()`; suppresses auto-reconnect until the next `connect()`.
    var userRequestedDisconnect = false
    var foregroundObserver: NSObjectProtocol?
    /// Token usage for the current session (see `[Cost]` log at teardown).
    var usageMeter = RealtimeUsageMeter()
    // Mid-session instruction refresh (see +SessionRefresh.swift)
    var refreshScheduler = SessionRefreshScheduler()
    var refreshTask: Task<Void, Never>?
    var instructionsObserver: NSObjectProtocol?

    // Dependencies
    let settings = OpenAISettings.shared
    let state = RealtimeChatState.shared

    // Function-call state (one active call at a time)
    var pendingFunctionCallId: String = ""
    var pendingFunctionName: String = ""
    var pendingFunctionArgsJSON: String = ""
    var deferredFunctionCall: (id: String, name: String, args: String)?

    /// True once THIS response streamed transcript text. `response.done`
    /// logs/stores the transcript only when set — a function-call-only
    /// response never clears `state.aiTranscript`, and logging it again
    /// duplicated the previous reply in the chat history.
    var hasFreshAITranscript = false

    /// Server-VAD segment timing per conversation item, so a transcript can
    /// be judged against how long the "speech" really lasted
    /// (`PhantomTranscriptFilter`). Entries are consumed on transcription.
    var speechStartMsByItem: [String: Int] = [:]
    var speechMsByItem: [String: Int] = [:]
    /// Set when the active response was cancelled because its user turn was
    /// a phantom: that response's `response.done` must not be logged.
    var phantomResponseCancelled = false

    // Post-audio execution: function waits until the AI's spoken audio finishes
    var audioPlaybackMonitorTask: Task<Void, Never>?
    // Set when the audio output item starts; anchors the speaking-duration estimate
    var speakingStartTime: Date?
    // Set when response.audio_transcript.done fires (real-time streaming signal)
    var transcriptDoneTime: Date?

    override init() {
        LKRTCInitializeSSL()
        let videoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = LKRTCDefaultVideoDecoderFactory()
        self.factory = LKRTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        let rtcSession = LKRTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setCategory(
                .playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
            try rtcSession.setMode(.videoChat)
            try rtcSession.setActive(true)
            // Manual audio so `isAudioEnabled` actually gates the audio
            // units (it is a no-op otherwise) — song recognition suspends
            // them to get an unprocessed mic signal.
            rtcSession.useManualAudio = true
            rtcSession.isAudioEnabled = true
            nlLog("[AI]: LKRTCAudioSession configured for speaker output", level: .info)
        } catch {
            nlLog("[AI]: Failed to configure LKRTCAudioSession: \(error)", level: .error)
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

    /// Starts the Realtime session. `isReconnect` is set by the auto-reconnect
    /// path so a user-facing call resets the reconnect bookkeeping.
    func connect(isReconnect: Bool = false) {
        guard settings.hasValidKey else {
            state.setError("Invalid API Key")
            return
        }
        if !isReconnect {
            userRequestedDisconnect = false
            cancelReconnect()
        }
        installForegroundWatch()
        installInstructionRefreshObserver()

        // Prevent redundant connection attempts if already active or connecting.
        guard
            state.status != .connecting && state.status != .ready && state.status != .speaking
                && state.status != .thinking
        else {
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

    /// Stops the Realtime session on the user's behalf; no auto-reconnect
    /// until the next `connect()`.
    func disconnect() {
        userRequestedDisconnect = true
        cancelReconnect()
        teardown()
    }

    /// Releases the transport without touching reconnect bookkeeping.
    func teardown() {
        if usageMeter.responses > 0 {
            nlLog(usageMeter.logLine, level: .info)
            usageMeter = RealtimeUsageMeter()
        }
        iceGatheringTimeout?.cancel()
        iceGatheringTimeout = nil
        pendingOffer = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshScheduler.reset()
        audioPlaybackMonitorTask?.cancel()
        audioPlaybackMonitorTask = nil
        speakingStartTime = nil
        transcriptDoneTime = nil
        AppFunctionExecutor.shared.pendingUIAction = nil
        PhoneEpisode.end(reason: "session torn down")
        micGateReasons.removeAll()
        sileroVAD.stop()
        ProactiveVisionManager.shared.stop()
        stopLipSyncFeed()
        remoteDataChannel?.close()
        peerConnection?.close()
        peerConnection = nil
        state.status = .disconnected
    }

    // MARK: - WebRTC Signaling

    func setupPeerConnection() {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.iceCandidatePoolSize = 10

        // Add STUN servers to help with NAT traversal
        config.iceServers = [
            LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            LKRTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            LKRTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"]),
            LKRTCIceServer(urlStrings: ["stun:stun3.l.google.com:19302"]),
            LKRTCIceServer(urlStrings: ["stun:stun4.l.google.com:19302"])
        ]

        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        self.peerConnection = factory.peerConnection(
            with: config, constraints: constraints, delegate: self)

        // Add Audio track
        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection?.add(audioTrack, streamIds: ["stream0"])
        self.localAudioTrack = audioTrack
        // Fresh track starts enabled — stale gate reasons from a previous
        // connection must not linger and mute it.
        micGateReasons.removeAll()

        // Setup Data Channel
        let dataChannelConfig = LKRTCDataChannelConfiguration()
        self.remoteDataChannel = peerConnection?.dataChannel(
            forLabel: "oai-events", configuration: dataChannelConfig)
        self.remoteDataChannel?.delegate = self
    }

    /// Suspends WebRTC's audio units for the song-recognition listen window.
    /// The voice-processing unit scrubs music out of the mic (AEC/noise
    /// suppression), which makes Shazam match attempts fail (code 202); the
    /// session also drops to `.default` mode so the raw mic reaches the
    /// recorder. The peer connection stays alive; `resumeAudioUnit()`
    /// restores voice mode. No-op when offline.
    func suspendAudioUnit() {
        guard peerConnection != nil else { return }
        let rtcSession = LKRTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        do {
            try rtcSession.setMode(.default)
        } catch {
            nlLog("[AI]: Failed to drop session mode for music capture: \(error)", level: .warning)
        }
        rtcSession.unlockForConfiguration()
        nlLog("[AI]: WebRTC audio suspended for music recognition", level: .info)
    }

    func resumeAudioUnit() {
        guard peerConnection != nil else { return }
        let rtcSession = LKRTCAudioSession.sharedInstance()
        // Restore the FULL WebRTC session configuration, not just the mode:
        // the capture window can leave the hardware at a different sample
        // rate (Shazam records at the device default), and restarting the
        // audio units against the wrong rate pitch-shifts/accelerates all
        // assistant speech until the next reconnect.
        let config = LKRTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setConfiguration(config, active: true)
        } catch {
            nlLog("[AI]: Failed to restore WebRTC session configuration: \(error)", level: .warning)
        }
        rtcSession.isAudioEnabled = true
        rtcSession.unlockForConfiguration()
        nlLog(
            "[AI]: WebRTC audio resumed after music recognition (rate \(config.sampleRate) Hz)",
            level: .info)
    }

    /// Why the outgoing mic track is currently gated. The track stays
    /// disabled while ANY reason is held, so overlapping holders (song
    /// recognition listening while the assistant announces, say) can't
    /// release each other's gate.
    enum MicGateReason: String {
        /// Song recognition is listening or announcing — the session must
        /// not hear the music (or our own TTS) as user speech.
        case songRecognition
        /// The assistant is speaking. Residual echo of its own voice that
        /// AEC misses (phone on a desk in PiP, speaker up) was reaching
        /// server_vad and coming back as phantom "user" turns; gate the
        /// track for the duration of the response instead.
        case assistantSpeaking
    }

    var micGateReasons: Set<MicGateReason> = []

    /// Gates or releases the outgoing mic for one reason; the track is
    /// re-enabled only when no reason remains. No-op when offline.
    func setMicGated(_ gated: Bool, reason: MicGateReason) {
        if gated {
            micGateReasons.insert(reason)
        } else {
            micGateReasons.remove(reason)
        }
        guard let track = localAudioTrack else { return }
        let shouldEnable = micGateReasons.isEmpty
        guard track.isEnabled != shouldEnable else { return }
        track.isEnabled = shouldEnable
        nlLog(
            "[AI]: Outgoing mic \(shouldEnable ? "restored" : "gated") (\(reason.rawValue))",
            level: .info)
    }

    func createAndSendOffer() {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: [
                kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue
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
                nlLog(
                    "[AI]: SDP offer set, gathering ICE candidates (timeout in 1.5s)...",
                    level: .info)
                self.pendingOffer = offer

                // Fallback timeout: Send what we have if gathering takes too long
                self.iceGatheringTimeout?.cancel()
                self.iceGatheringTimeout = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        nlLog(
                            "[AI]: ICE gathering timeout reached, sending available candidates",
                            level: .info)
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

    func stopLipSyncFeed() {
        lipSync.detach()
    }

    // MARK: - Silero VAD

    func startSileroVADIfEnabled() {
        guard settings.isVADEnabled else { return }
        sileroVAD.delegate = self
        sileroVAD.start()
    }
}
