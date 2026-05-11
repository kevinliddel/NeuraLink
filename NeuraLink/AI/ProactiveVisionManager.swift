//
//  ProactiveVisionManager.swift
//  NeuraLink
//
//  Handles the background vision loop, periodically capturing camera frames
//  and sending descriptions to the AI for proactive interaction.
//

import Foundation
import UIKit
import WebRTC

final class ProactiveVisionManager {
    static let shared = ProactiveVisionManager()
    
    private var visionTask: Task<Void, Never>?
    private let cameraManager = CameraManager.shared
    private let aiManager = OpenAIRealtimeManager.shared
    private let settings = OpenAISettings.shared
    
    private init() {}
    
    /// Starts the proactive vision loop.
    func start() {
        visionTask?.cancel()
        visionTask = Task {
            while !Task.isCancelled {
                // Wait for the next interval (e.g., 20 seconds)
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                if Task.isCancelled { break }
                
                guard shouldAnalyze() else { continue }
                
                await performAnalysis()
            }
        }
        print("[ProactiveVision] Started")
    }
    
    /// Stops the proactive vision loop.
    func stop() {
        visionTask?.cancel()
        visionTask = nil
        print("[ProactiveVision] Stopped")
    }
    
    private func shouldAnalyze() -> Bool {
        // 1. Must be enabled in settings
        guard settings.isProactiveVisionEnabled else { return false }
        
        // 2. Camera must be active
        guard cameraManager.isActive else { return false }
        
        // 3. AI must be ready (not speaking or listening)
        guard aiManager.state.status == .ready else { return false }
        
        // 4. OpenAI Realtime must be connected (data channel open)
        guard aiManager.remoteDataChannel?.readyState == .open else { return false }
        
        return true
    }
    
    private func performAnalysis() async {
        // Capture frame on MainActor
        let image = await MainActor.run {
            cameraManager.captureCurrentFrame()
        }
        
        guard let image = image else { return }
        
        print("[ProactiveVision] Capturing frame for analysis...")
        
        // Perform analysis using GPT-4o Vision
        let prompt = "Describe the user's current environment and what they are doing in a single, natural sentence. Focus on details that would be interesting for a companion to comment on."
        let description = await VisionAnalyzer.analyze(
            image: image,
            prompt: prompt,
            apiKey: settings.apiKey
        )
        
        guard !description.isEmpty && !description.contains("error") && !description.contains("Could not parse") else {
            print("[ProactiveVision] Analysis failed or returned error: \(description)")
            return
        }
        
        // Send to AI
        aiManager.sendProactiveVisionUpdate(description: description)
    }
}
