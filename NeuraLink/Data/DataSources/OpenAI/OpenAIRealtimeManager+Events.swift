//
//  OpenAIRealtimeManager+Events.swift
//  NeuraLink
//
//  Outbound data-channel events that make the assistant react or speak:
//  interaction events (head-pats, proactive vision, song matches) and the
//  verbatim title announcement. Split from +Handlers to stay under the
//  file-length ceiling.
//
//  Created by Dedicatus on 31/08/2026.
//

import Foundation
import WebRTC

extension OpenAIRealtimeManager {
    /// Makes the assistant SAY a literal line (e.g. the song-recognition
    /// title announcement). Uses the normal response pipeline, so the audio
    /// is audible through the live session and the transcript handler logs
    /// it to chat history like any other assistant turn.
    func speakVerbatim(_ line: String) {
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    [
                        "type": "input_text",
                        "text":
                            "Announce to the user, saying exactly this and nothing else: \(line)",
                    ]
                ],
            ],
        ]
        let trigger: [String: Any] = ["type": "response.create"]

        for payload in [item, trigger] {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            remoteDataChannel?.sendData(buffer)
        }
        nlLog("[AI]: verbatim announcement requested", level: .info)
    }

    func sendInteractionEvent(_ action: String) {
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [
                    ["type": "input_text", "text": action]
                ],
            ],
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
