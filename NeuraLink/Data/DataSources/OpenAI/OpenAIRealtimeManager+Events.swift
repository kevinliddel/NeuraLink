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
        send(["type": "response.cancel"])
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
        send(item)
        send(["type": "response.create"])
        nlLog("[AI Interaction]: sent event: \(action)", level: .info)
    }
}
