//
//  PhotoshootSkill.swift
//  NeuraLink
//
//  Allows the AI to strike a pose and hide the UI for a clean screenshot.
//

import Foundation
import SwiftUI

@MainActor
final class PhotoshootSkill: Skill {
    static let toolName = AppFunctionTool.poseForPhoto
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        guard let pose = arguments["pose"] as? String else {
            return "I couldn't strike a pose without a pose name."
        }

        // 1. Trigger the animation in VRMMetalState
        // We'll use a notification or a direct call if we can find the state
        NotificationCenter.default.post(
            name: Notification.Name("VRMPlayPoseAnimation"),
            object: nil,
            userInfo: ["pose": pose]
        )

        // 2. Hide the UI
        RealtimeChatState.shared.isUIHidden = true

        // 3. Schedule UI restoration after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            RealtimeChatState.shared.isUIHidden = false
        }

        return "Okay! I'm striking my \(pose) pose now. I'll hide the UI so you can take a clean photo!"
    }
}
