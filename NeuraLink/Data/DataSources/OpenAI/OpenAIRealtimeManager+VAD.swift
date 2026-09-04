//
//  OpenAIRealtimeManager+VAD.swift
//  NeuraLink
//
//  Client-side Silero VAD delegate: instant listening/ready UI state
//  alongside OpenAI's server_vad, and barge-in release of the mic gate
//  while the assistant is speaking.
//

import Foundation

// MARK: - Silero VAD

extension OpenAIRealtimeManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        // Barge-in: the mic track is gated while the assistant speaks (see
        // the `assistantSpeaking` gate reason). Silero listens to the
        // AEC-processed input, so a trigger here is real user speech, not
        // the assistant's own output — lift the gate so server_vad can
        // hear the interruption. Best-effort: if Silero's engine failed to
        // start, barge-in waits for response.done instead.
        if state.status == .speaking {
            setMicGated(false, reason: .assistantSpeaking)
            nlLog("[SileroVAD]: Voice during assistant speech → mic gate lifted for barge-in", level: .info)
            return
        }
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
