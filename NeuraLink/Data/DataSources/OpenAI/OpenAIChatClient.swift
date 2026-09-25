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

    /// Default text model for every background call (titling, reflection,
    /// memory retain / consolidation / mental models). User-selectable in
    /// AI Settings → Models; this is the catalog default.
    nonisolated static let defaultModel = OpenAIModelCatalog.defaultID(for: .text)

    /// GPT-5-family models reject a non-default `temperature`; older models
    /// accept it. Everything current accepts `max_completion_tokens`.
    nonisolated static func supportsTemperature(_ model: String) -> Bool {
        !model.lowercased().hasPrefix("gpt-5")
    }

    /// Sends one system+user exchange and returns the assistant's text, or
    /// nil on any failure (missing key, transport, non-2xx, parse). Callers
    /// treat nil as "skip silently" — these are background nice-to-haves.
    static func complete(
        system: String,
        user: String,
        model explicitModel: String? = nil,
        maxTokens: Int,
        temperature: Double = 0.3
    ) async -> String? {
        let key = OpenAISettings.shared.apiKey
        let model = explicitModel ?? OpenAISettings.shared.textModel
        guard !key.isEmpty, let url = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "max_completion_tokens": maxTokens
        ]
        if supportsTemperature(model) { body["temperature"] = temperature }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            // The error body names the offending parameter — worth having
            // when a model rejects a request shape.
            let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            nlLog("[OpenAIChatClient] \(model) call failed: HTTP \(http.statusCode) \(detail)", level: .warning)
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        if let usage = json["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let completion = usage["completion_tokens"] as? Int ?? 0
            nlLog("[Cost] text model=\(model) in=\(prompt) out=\(completion)", level: .info)
        }
        return content
    }
}
