//
//  AutonomySettingsView.swift
//  NeuraLink
//
//  Dedicated screen for the character's autonomous behaviors, pushed from
//  AISettingsView (same pattern as PersonaSettingsView). Extracted once the
//  Living Companion toggles outgrew a single inline section: each feature
//  gets its own titled section with a footer explanation instead of the
//  cramped info-popover buttons.
//
//  Created by Dedicatus on 09/09/2026.
//

import SwiftUI

struct AutonomySettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @Bindable var presence = PresenceSettings.shared

    var body: some View {
        Form {
            conversationSection
            visionSection
            presenceSection
            engagementSection
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Autonomy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Conversation

    private var conversationSection: some View {
        Section {
            Toggle("Auto-Turn Detection (VAD)", isOn: $settings.isVADEnabled)
                .disabled(!settings.isEnabled)
        } header: {
            Text("Conversation")
        } footer: {
            Text("The character replies automatically when you stop speaking. Requires OpenAI voice mode.")
        }
    }

    // MARK: - Proactive Vision

    private var visionSection: some View {
        Section {
            Toggle("Proactive Vision", isOn: $settings.isProactiveVisionEnabled)
                .disabled(!settings.isEnabled)

            if settings.isEnabled && settings.isProactiveVisionEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interval")
                    DropDownSelector(items: [10.0, 20.0, 30.0, 60.0], selection: $settings.proactiveVisionIntervalSec) { seconds in
                        "\(Int(seconds))s"
                    }
                }
                .listRowSeparator(.hidden)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Cooldown after speech")
                    DropDownSelector(items: [0.0, 8.0, 12.0, 20.0], selection: $settings.proactiveVisionCooldownAfterSpeechSec) { seconds in
                        "\(Int(seconds))s"
                    }
                }
            }
        } header: {
            Text("Proactive Vision")
        } footer: {
            Text("Periodically looks through the camera and comments on what it sees, without being asked. Requires OpenAI voice mode and the camera.")
        }
    }

    // MARK: - Companion Presence

    private var presenceSection: some View {
        Section {
            Toggle("Companion Presence", isOn: $presence.isPresenceEnabled)

            if presence.isPresenceEnabled {
                Toggle("\"Thinking of you\" notifications", isOn: $presence.isNotificationsEnabled)
            }
        } header: {
            Text("Companion Presence")
        } footer: {
            Text(
                "After each conversation the character reflects on it — keeping a diary, learning personality notes, and preparing a greeting for next time. Everything stays on this device; review or erase it anytime by tapping the relationship meter."
            )
        }
    }

    // MARK: - Proactive Engagement

    private var engagementSection: some View {
        Section {
            Toggle("Proactive Engagement", isOn: $presence.isProactiveEngagementEnabled)

            if presence.isProactiveEngagementEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Greet after time away")
                    DropDownSelector(items: [1.0, 6.0, 12.0, 24.0], selection: $presence.absenceGreetingHours) { hours in
                        "\(Int(hours))h"
                    }
                }
                .listRowSeparator(.hidden)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Break silence after")
                    DropDownSelector(items: [45.0, 90.0, 180.0, 300.0], selection: $presence.silenceSmallTalkSec) { seconds in
                        "\(Int(seconds))s"
                    }
                }
            }
        } header: {
            Text("Proactive Engagement")
        } footer: {
            Text("The character speaks first — greeting you when you return after time away, and breaking long silences with a short line of its own. Works with both OpenAI and the local model.")
        }
    }
}

#Preview {
    NavigationStack {
        AutonomySettingsView()
    }
}
