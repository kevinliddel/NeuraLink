//
//  OpenAppSkill.swift
//  NeuraLink
//
//  Opens a built-in iOS app by name.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation
import UIKit

@MainActor
final class OpenAppSkill: Skill {
    static let toolName = AppFunctionTool.openApp
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        let app = arguments["app"] as? String ?? ""
        return openApp(named: app)
    }

    private func openApp(named app: String) -> String {
        if app == "Settings" {
            pendingUIAction = { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            return "Opening Settings for you."
        }

        let schemeMap: [String: String] = [
            "Maps": "maps://",
            "Photos": "photos-redirect://",
            "Calendar": "calshow://",
            "Camera": "camera://",
            "Clock": "clock-alarm://",
            "Health": "x-apple-health://",
            "FaceTime": "facetime://"
        ]
        guard let scheme = schemeMap[app],
            let url = URL(string: scheme),
            UIApplication.shared.canOpenURL(url)
        else {
            return "I wasn't able to open \(app) directly. Please launch it from your home screen."
        }
        pendingUIAction = { UIApplication.shared.open(url) }
        return "Opening \(app) for you."
    }
}
