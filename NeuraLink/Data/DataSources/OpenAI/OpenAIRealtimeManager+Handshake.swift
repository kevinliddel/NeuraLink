//
//  OpenAIRealtimeManager+Handshake.swift
//  NeuraLink
//
//  The GA two-step connection handshake: mint an ephemeral key at
//  /v1/realtime/client_secrets (where the model id and voice are fixed),
//  then POST the SDP offer to /v1/realtime/calls with that key. Split from
//  the core manager for the SwiftLint 495-line limit.
//

import Foundation
import WebRTC

extension OpenAIRealtimeManager {

    func sendOfferToOpenAI(_ offer: RTCSessionDescription) {
        // GA two-step handshake (replaces the deprecated direct-key SDP POST,
        // which now returns `beta_api_shape_disabled`):
        //   1. POST /v1/realtime/client_secrets with master API key →
        //      JSON body containing `client_secret.value` (an ephemeral
        //      token valid for ~1 minute).
        //   2. POST /v1/realtime?model=... with the ephemeral token as
        //      Bearer auth and the SDP offer body.
        // The master API key is therefore the only thing that touches
        // the auth endpoint; the SDP POST uses the short-lived secret.
        // Resolve the persona once per handshake so the session is born with
        // the right voice (see `requestEphemeralKey` for the full rationale).
        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        requestEphemeralKey(persona: persona) { [weak self] ephemeralKey, errorMessage in
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
    ///
    /// `persona.voice` is seeded into the session here because the GA API
    /// freezes voice once any assistant audio is in flight — sending it in
    /// a later `session.update` triggers `cannot_update_voice` and drops the
    /// envelope. `persona.instructions` is also seeded so the model has the
    /// right system prompt in the small window before our follow-up
    /// `session.update` arrives with the full RAG-augmented context.
    func requestEphemeralKey(
        persona: CharacterPersona,
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
                "model": "gpt-realtime-2.1-mini",
                "instructions": persona.instructions,
                "audio": [
                    "output": ["voice": persona.voice]
                ]
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
                    nlLog(
                        "[AI]: Ephemeral key minted (status=\(status), top-level shape)",
                        level: .info)
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
    func postSDPOffer(_ offer: RTCSessionDescription, ephemeralKey: String) {
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
            let contentType =
                (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            nlLog(
                "[AI]: Received answer length: \(sdpAnswer.count) status=\(httpStatus) content-type=\(contentType)",
                level: .info)
            if !sdpAnswer.hasPrefix("v=0") {
                let preview = String(sdpAnswer.prefix(500))
                nlLog("[AI]: Non-SDP body (likely an error): \(preview)", level: .warning)
                Task { @MainActor in
                    self.state.setError(
                        "OpenAI returned HTTP \(httpStatus) instead of SDP. Body preview: \(preview.prefix(120))"
                    )
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
}
