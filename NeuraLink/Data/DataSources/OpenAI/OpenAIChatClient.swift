//
//  OpenAIChatClient.swift
//  NeuraLink
//
//  One-shot Chat Completions client — Living Companion Phase 0
//  (docs/LIVING_COMPANION_PLAN.md §0.4). Consolidates the hand-rolled
//  URLRequest copies (ConversationTitler, VisionAnalyzer, TTS callers) so
//  background text calls (titling, reflection) share one implementation.
//  The Realtime/WebRTC voice path is separate and unaffected.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation

enum OpenAIChatClient {

    private static let endpoint = "https://api.openai.com/v1/chat/completions"

    /// Sends one system+user exchange and returns the assistant's text, or
    /// nil on any failure (missing key, transport, non-2xx, parse). Callers
    /// treat nil as "skip silently" — these are background nice-to-haves.
    static func complete(
        system: String,
        user: String,
        model: String = "gpt-4o-mini",
        maxTokens: Int,
        temperature: Double = 0.3
    ) async -> String? {
        let key = OpenAISettings.shared.apiKey
        guard !key.isEmpty, let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            nlLog("[OpenAIChatClient] \(model) call failed: HTTP \(http.statusCode)", level: .warning)
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return content
    }
}
