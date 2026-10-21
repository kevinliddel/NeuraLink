//
//  AutonomyPreset.swift
//  NeuraLink
//
//  Three ready-made levels of initiative for the Autonomy screen, so the
//  companion's behaviour is a choice before it is a wall of switches
//  (docs/LIVING_COMPANION.md). A preset governs the switches that need no
//  permission; camera, calendar, Health and the desk stay as the user set
//  them. Pure and unit-tested; the settings bridge lives in Data.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

/// The switches a preset decides.
struct AutonomyFlags: Equatable, Sendable {
    var autoTurn = true
    var interrupt = false
    var senseTone = false
    var keepTalking = false
    var presence = false
    var notifications = false
    var followUps = false
    var widgets = false
    var engagement = false

    var onCount: Int {
        [autoTurn, interrupt, senseTone, keepTalking, presence, notifications, followUps, widgets, engagement]
            .filter { $0 }.count
    }
}

enum AutonomyPreset: String, CaseIterable, Sendable {
    case quiet, balanced, lively

    var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .lively: return "Lively"
        }
    }

    var symbol: String {
        switch self {
        case .quiet: return "moon.fill"
        case .balanced: return "scale.3D"
        case .lively: return "sparkles"
        }
    }

    /// One line under the picker.
    var blurb: String {
        switch self {
        case .quiet: return "Answers when spoken to. Nothing between sessions, no notifications."
        case .balanced: return "Remembers and reflects, follows up on plans, keeps the widgets fresh — but waits for you to start."
        case .lively: return "Speaks first, greets you back, keeps talking in the background and sends a note when you're away."
        }
    }

    var flags: AutonomyFlags {
        switch self {
        case .quiet:
            return AutonomyFlags()
        case .balanced:
            return AutonomyFlags(
                autoTurn: true, interrupt: true, senseTone: true, keepTalking: false,
                presence: true, notifications: false, followUps: true, widgets: true, engagement: false)
        case .lively:
            return AutonomyFlags(
                autoTurn: true, interrupt: true, senseTone: true, keepTalking: true,
                presence: true, notifications: true, followUps: true, widgets: true, engagement: true)
        }
    }

    /// The preset these switches match exactly, or nil for a custom mix.
    static func matching(_ flags: AutonomyFlags) -> AutonomyPreset? {
        allCases.first { $0.flags == flags }
    }
}
