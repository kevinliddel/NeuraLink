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

    private var lastAnalysisAt: Date?
    private var lastUserSpeechAt: Date?
    private var lastSummaryNormalized: String = ""
    
    private init() {}
    
    /// Starts the proactive vision loop.
    func start() {
        visionTask?.cancel()
        visionTask = Task {
            while !Task.isCancelled {
                let interval = max(5, settings.proactiveVisionIntervalSec)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
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
        lastAnalysisAt = nil
        lastUserSpeechAt = nil
        lastSummaryNormalized = ""
        print("[ProactiveVision] Stopped")
    }

    func notifyUserSpoke() {
        lastUserSpeechAt = Date()
    }
    
    private func shouldAnalyze() -> Bool {
        // 1. Must be enabled in settings
        guard settings.isProactiveVisionEnabled else { return false }
        guard !settings.isProactiveVisionPrivateModeEnabled else { return false }
        
        // 2. Camera must be active
        guard cameraManager.isActive else { return false }

        // 2.5 Privacy / environment guardrails
        if settings.proactiveVisionOnlyWhenUnlocked && !UIApplication.shared.isProtectedDataAvailable {
            return false
        }

        if settings.proactiveVisionOnlyInForeground {
            let inForeground = UIApplication.shared.applicationState == .active
            let allowPiP = settings.proactiveVisionAllowInPiP && PiPManager.shared.isPiPActive
            guard inForeground || allowPiP else { return false }
        }
        
        // 3. AI must be ready (not speaking or listening)
        guard aiManager.state.status == .ready else { return false }
        
        // 4. OpenAI Realtime must be connected (data channel open)
        guard aiManager.remoteDataChannel?.readyState == .open else { return false }

        // 5. Cooldown after the user speaks to avoid interrupting a conversation
        if let last = lastUserSpeechAt {
            let cooldown = max(0, settings.proactiveVisionCooldownAfterSpeechSec)
            if Date().timeIntervalSince(last) < cooldown {
                return false
            }
        }

        // 6. Rate limit even if the task loop is rescheduled
        if let last = lastAnalysisAt, Date().timeIntervalSince(last) < max(5, settings.proactiveVisionIntervalSec) {
            return false
        }
        
        return true
    }
    
    private func performAnalysis() async {
        lastAnalysisAt = Date()
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
        
        let normalized = Self.normalize(description)
        guard normalized != lastSummaryNormalized else {
            print("[ProactiveVision] Skipping duplicate summary")
            return
        }
        lastSummaryNormalized = normalized

        // Send to AI
        aiManager.sendProactiveVisionUpdate(description: description)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[\s\p{Punct}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
