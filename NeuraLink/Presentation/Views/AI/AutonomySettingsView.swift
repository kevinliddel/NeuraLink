//
//  AutonomySettingsView.swift
//  NeuraLink
//
//  Dedicated screen for the character's autonomous behaviors, pushed from
//  AISettingsView (same pattern as PersonaSettingsView). One section per
//  feature groups its toggle with its tuning dropdowns; each toggle carries
//  an ⓘ button that pops a short explanation.
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
            backgroundSection
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
            Toggle(isOn: $settings.isVADEnabled) {
                InfoToggleLabel(
                    title: "Auto-Turn Detection (VAD)",
                    info: "The character replies automatically when you stop speaking. Requires OpenAI voice mode."
                )
            }
            .disabled(!settings.isEnabled)

            Toggle(isOn: $settings.isLocalBargeInEnabled) {
                InfoToggleLabel(
                    title: "Interrupt while speaking (local)",
                    info: "Start talking over the local assistant to cut its reply short. Uses echo-aware detection; turn off if it triggers on its own voice."
                )
            }
            .disabled(!settings.isLocalLLMEnabled)
        }
    }

    // MARK: - Background audio (docs/PRESENCE_BEYOND_APP_PLAN.md §P1)

    private var backgroundSection: some View {
        Section {
            Toggle(isOn: $presence.keepTalkingInBackground) {
                InfoToggleLabel(
                    title: "Keep talking in background",
                    info: "The conversation keeps going with the screen off or while you use other apps, with AirPods or the speaker. The microphone stays on (iOS shows the orange indicator) until you stop talking for the idle time below, Low Power Mode turns on, or the phone gets hot."
                )
            }
            .listRowSeparator(presence.keepTalkingInBackground ? .hidden : .automatic)

            if presence.keepTalkingInBackground {
                VStack(alignment: .leading, spacing: 4) {
                    Text("End after silence")
                    DropDownSelector(
                        items: [5.0, 10.0, 20.0, 30.0], selection: $presence.backgroundIdleMinutes
                    ) { minutes in
                        "\(Int(minutes)) minutes"
                    }
                }
            }
        }
    }

    // MARK: - Proactive Vision

    private var visionSection: some View {
        Section {
            Toggle(isOn: $settings.isProactiveVisionEnabled) {
                InfoToggleLabel(
                    title: "Proactive Vision",
                    info: "The character periodically looks through the camera and comments on what it sees, without being asked. Requires OpenAI voice mode and the camera."
                )
            }
            .disabled(!settings.isEnabled)
            .listRowSeparator(settings.isEnabled && settings.isProactiveVisionEnabled ? .hidden : .automatic)

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
        }
    }

    // MARK: - Companion Presence

    private var presenceSection: some View {
        Section {
            Toggle(isOn: $presence.isPresenceEnabled) {
                InfoToggleLabel(
                    title: "Companion Presence",
                    info: "After each conversation the character reflects on it — keeping a diary, learning personality notes, and preparing a greeting for next time. Everything stays on this device; review or erase it anytime by tapping the relationship meter."
                )
            }

            if presence.isPresenceEnabled {
                Toggle(isOn: $presence.isNotificationsEnabled) {
                    InfoToggleLabel(
                        title: "\"Thinking of you\" notifications",
                        info: "Hours after a conversation ends, a single gentle notification arrives with what the character has been thinking about. Never during quiet hours (22:00–09:00)."
                    )
                }
            }

            Toggle(isOn: $presence.followUpsEnabled) {
                InfoToggleLabel(
                    title: "Follow up on plans",
                    info: "When you mention something with a date — a trip, an appointment, a birthday — the character brings it up the day before and asks how it went afterwards. Notifications need the toggle above; \"Not this\" on a notification silences that plan."
                )
            }

            Toggle(isOn: $presence.showWidgets) {
                InfoToggleLabel(
                    title: "Companion widgets",
                    info: "Home and lock-screen widgets show the character's greeting, how close you are and how long since you talked. They read a small summary stored outside the encrypted memory database — never your conversations or facts. Off removes it."
                )
            }
        }
    }

    // MARK: - Proactive Engagement

    private var engagementSection: some View {
        Section {
            Toggle(isOn: $presence.isProactiveEngagementEnabled) {
                InfoToggleLabel(
                    title: "Proactive Engagement",
                    info: "The character speaks first — greeting you when you return after time away, and breaking long silences with a short line of its own. Works with both OpenAI and the local model."
                )
            }
            .listRowSeparator(presence.isProactiveEngagementEnabled ? .hidden : .automatic)

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
        }
    }
}

// MARK: - Toggle label with ⓘ popover

/// A toggle label with an ⓘ button that pops a short explanation — the house
/// info idiom, self-contained so every feature row can reuse it.
#Preview {
    NavigationStack {
        AutonomySettingsView()
    }
}
