//
//  AutonomyPresets.swift
//  NeuraLink
//
//  Bridges `AutonomyPreset` (pure) to the settings objects: read the
//  switches it governs, and write a preset back. Permission-gated switches
//  (camera, desk, calendar, Health) are deliberately not part of a preset.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

extension AutonomyPreset {

    /// The switches as they are set right now.
    static func currentFlags() -> AutonomyFlags {
        let openAI = OpenAISettings.shared
        let presence = PresenceSettings.shared
        return AutonomyFlags(
            autoTurn: openAI.isVADEnabled,
            interrupt: openAI.isLocalBargeInEnabled,
            senseTone: AffectSettings.shared.isEnabled,
            keepTalking: presence.keepTalkingInBackground,
            presence: presence.isPresenceEnabled,
            notifications: presence.isNotificationsEnabled,
            followUps: presence.followUpsEnabled,
            widgets: presence.showWidgets,
            engagement: presence.isProactiveEngagementEnabled,
            gestures: MotionSettings.shared.isEnabled)
    }

    /// The preset the current switches match, or nil for a custom mix.
    static func current() -> AutonomyPreset? {
        matching(currentFlags())
    }

    /// Writes the preset's switches; each setter keeps its own side effects
    /// (the notification permission request, widget cleanup, …).
    func apply() {
        let flags = self.flags
        let openAI = OpenAISettings.shared
        let presence = PresenceSettings.shared
        if openAI.isVADEnabled != flags.autoTurn { openAI.isVADEnabled = flags.autoTurn }
        if openAI.isLocalBargeInEnabled != flags.interrupt { openAI.isLocalBargeInEnabled = flags.interrupt }
        if AffectSettings.shared.isEnabled != flags.senseTone { AffectSettings.shared.isEnabled = flags.senseTone }
        if presence.keepTalkingInBackground != flags.keepTalking { presence.keepTalkingInBackground = flags.keepTalking }
        if presence.isPresenceEnabled != flags.presence { presence.isPresenceEnabled = flags.presence }
        if presence.isNotificationsEnabled != flags.notifications { presence.isNotificationsEnabled = flags.notifications }
        if presence.followUpsEnabled != flags.followUps { presence.followUpsEnabled = flags.followUps }
        if presence.showWidgets != flags.widgets { presence.showWidgets = flags.widgets }
        if presence.isProactiveEngagementEnabled != flags.engagement {
            presence.isProactiveEngagementEnabled = flags.engagement
        }
        if MotionSettings.shared.isEnabled != flags.gestures { MotionSettings.shared.isEnabled = flags.gestures }
        nlLog("[Autonomy] preset applied: \(rawValue)", level: .info)
    }
}
