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
    /// Cancels any in-flight assistant response. Song recognition calls
    /// this when it starts listening so a mid-sentence reply can't resume
    /// after the capture window and talk over the flow — the only assistant
    /// output around a recognition is the title announcement afterwards.
    func cancelActiveResponse() {
        let payload: [String: Any] = ["type": "response.cancel"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        remoteDataChannel?.sendData(RTCDataBuffer(data: data, isBinary: false))
        nlLog("[AI]: active response cancelled (song recognition)", level: .info)
    }

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
