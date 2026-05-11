//
//  CameraSkill.swift
//  NeuraLink
//
//  Analyzes the current camera frame via VisionAnalyzer.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation

@MainActor
final class CameraSkill: Skill {
    static let toolName = AppFunctionTool.analyzeCamera
    var pendingUIAction: (() -> Void)?
    
    private let settings = OpenAISettings.shared

    func execute(arguments: [String: Any]) async -> String {
        let prompt = arguments["prompt"] as? String
        return await analyzeCamera(prompt: prompt)
    }

    private func analyzeCamera(prompt: String?) async -> String {
        guard CameraManager.shared.isActive else {
            return "The camera is not active. Ask the user to enable it first."
        }
        guard let image = CameraManager.shared.captureCurrentFrame() else {
            return "Could not capture a frame from the camera right now."
        }
        let description = prompt ?? "Describe what you see in this image concisely and naturally."
        return await VisionAnalyzer.analyze(
            image: image,
            prompt: description,
            apiKey: settings.apiKey
        )
    }
}
