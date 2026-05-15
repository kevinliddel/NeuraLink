//
//  VisionAnalyzer.swift
//  NeuraLink
//
//  Sends a camera frame to GPT-4o Vision and returns a plain-text description.
//  Used by AppFunctionExecutor when the AI calls the analyze_camera tool.
//

import Foundation
import UIKit

enum VisionAnalyzer {

    private static let endpoint = "https://api.openai.com/v1/chat/completions"
    private static let model = "gpt-4o"
    private static let maxTokens = 300

    /// Encodes `image` as JPEG, sends it to GPT-4o Vision, and returns the description.
    static func analyze(image: UIImage, prompt: String, apiKey: String) async -> String {
        guard !apiKey.isEmpty else { return "No API key configured." }

        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            return "Failed to encode camera frame."
        }

        let body = buildBody(base64Image: imageData.base64EncodedString(), prompt: prompt)

        guard
            let url = URL(string: endpoint),
            let bodyData = try? JSONSerialization.data(withJSONObject: body)
        else {
            return "Failed to build vision request."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return extractContent(from: data)
        } catch {
            return "Vision error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private static func buildBody(base64Image: String, prompt: String) -> [String: Any] {
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            [
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
            ]
        ]
        return [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "max_tokens": maxTokens
        ]
    }

    private static func extractContent(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            return "Could not parse the vision response."
        }
        return content
    }
}
