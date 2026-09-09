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
private struct InfoToggleLabel: View {
    let title: String
    let info: String

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfo) {
                Text(info)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: 280)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel("About \(title)")
        }
    }
}

#Preview {
    NavigationStack {
        AutonomySettingsView()
    }
}
