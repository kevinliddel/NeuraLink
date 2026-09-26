//
//  ShowPhotoSkill.swift
//  NeuraLink
//
//  `show_photo` tool — opens the photo picker so the user can show the
//  companion a picture (docs/COMPANION_DEPTH_PLAN.md §D2).
//

import Foundation

@MainActor
final class ShowPhotoSkill: Skill {
    static let toolName = AppFunctionTool.showPhoto
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        NotificationCenter.default.post(name: .photoMemoryPickerRequested, object: nil)
        return "Opening your photos — pick one and I'll take a look."
    }
}
