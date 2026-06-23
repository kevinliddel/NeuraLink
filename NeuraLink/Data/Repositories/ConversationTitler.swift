//
//  ConversationTitler.swift
//  NeuraLink
//
//  Auto-titles a conversation once it reaches a few turns, using whichever AI
//  is currently active (SynapLink-style). OpenAI uses a one-shot Chat
//  Completions call (the Realtime session is voice, so titling goes through a
//  separate text model); the local LLM uses the existing silent-generation
//  path. Falls back silently to the first-message title if generation fails.
//

import Foundation

final class ConversationTitler: @unchecked Sendable {
    static let shared = ConversationTitler()

    /// Generate a title once the conversation reaches this many messages.
    private static let titleAfterMessages = 5

    private let lock = NSLock()
    private var inFlight: Set<Int64> = []

    private init() {}

    /// Fire-and-forget. No-ops unless the conversation has ≥5 messages, isn't
    /// already auto-titled, and isn't already being titled.
    func maybeAutoTitle(conversationID: Int64) {
        guard !MemoryStore.shared.conversationAutoTitled(id: conversationID),
              MemoryStore.shared.messageCount(conversationID: conversationID) >= Self.titleAfterMessages
        else { return }

        lock.lock()
        guard !inFlight.contains(conversationID) else { lock.unlock(); return }
        inFlight.insert(conversationID)
        lock.unlock()

        Task.detached(priority: .background) { [weak self] in
            defer { self?.finish(conversationID) }
            let messages = MemoryStore.shared.fetchMessages(conversationID: conversationID)
            let transcript = Self.transcript(from: messages)
            guard !transcript.isEmpty else { return }
            guard let title = await Self.generateTitle(transcript: transcript) else { return }
            MemoryStore.shared.renameConversation(id: conversationID, title: title, autoTitled: true)
            nlLog("[Titler] Auto-titled conversation \(conversationID): \(title)", level: .info)
        }
    }

    private func finish(_ id: Int64) {
        lock.lock(); inFlight.remove(id); lock.unlock()
    }

    // MARK: - Generation

    private static func generateTitle(transcript: String) async -> String? {
        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            return await titleViaOpenAI(transcript: transcript)
        }
        // Local LLM path — reuse the silent generator (no UI/TTS side effects).
        guard LocalLLMManager.shared.llmEngine.isLoaded else { return nil }
        let raw = await LocalLLMManager.shared.runSilentGeneration(
            prompt: localPrompt(transcript: transcript), maxTokens: 16)
        return clean(raw)
    }

    private static func titleViaOpenAI(transcript: String) async -> String? {
        let key = OpenAISettings.shared.apiKey
        guard !key.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/chat/completions")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemInstruction],
                ["role": "user", "content": transcript]
            ],
            "max_tokens": 16,
            "temperature": 0.3
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return clean(content)
    }

    // MARK: - Prompt + transcript

    private static let systemInstruction =
        "You write a concise chat title of 3–5 words for the conversation below. " +
        "Reply with only the title — no quotes, no punctuation, no prefix."

    private static func localPrompt(transcript: String) -> String {
        "\(systemInstruction)\n\nConversation:\n\(transcript)\n\nTitle:"
    }

    /// First several verbatim turns, capped so the prompt stays small.
    private static func transcript(from messages: [ConversationMessage]) -> String {
        messages
            .filter { $0.kind == "message" }
            .prefix(8)
            .map { "\($0.isUser ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n")
    }

    /// First line, stripped of quotes / "Title:" prefix, capped to a short label.
    private static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(where: \.isNewline) { t = String(t[..<nl]) }
        if let range = t.range(of: "title:", options: .caseInsensitive) {
            t = String(t[range.upperBound...])
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”.“”"))
        t = String(t.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
