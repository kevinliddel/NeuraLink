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

    static let availablePoses = ["cool", "peace_sign", "relax", "stretch"]

    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        let requested = arguments["pose"] as? String ?? ""
        let pose = Self.availablePoses.contains(requested)
            ? requested
            : Self.availablePoses.randomElement()!

        NotificationCenter.default.post(
            name: Notification.Name("VRMPlayPoseAnimation"),
            object: nil,
            userInfo: ["pose": pose]
        )

        RealtimeChatState.shared.isUIHidden = true
        PhotoshootShareController.shared.schedulePhoto()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            RealtimeChatState.shared.isUIHidden = false
        }
        // The pose ends with the photo window — without it the body stayed
        // in the pose (idles and talking gestures paused) for the session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            NotificationCenter.default.post(name: Notification.Name("VRMStopPoseAnimation"), object: nil)
        }

        return "Okay! Striking my \(pose.replacingOccurrences(of: "_", with: " ")) pose — smile!"
    }
}
