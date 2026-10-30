//
//  AutonomySettingsView.swift
//  NeuraLink
//
//  How much the companion does on her own (docs/LIVING_COMPANION.md). A
//  preset header first — Quiet / Balanced / Lively — then four cards, one
//  per sense: talking, seeing, between sessions, knowing your day. Every
//  switch has a face (tile, one line of meaning, ⓘ for the rest) and its
//  sub-settings slot in under it while it is on.
//
//  Created by Dedicatus on 20/10/2026 (previously one section per switch).
//

import SwiftUI

struct AutonomySettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @Bindable var presence = PresenceSettings.shared
    @Bindable var grounding = GroundingSettings.shared
    @Bindable var affect = AffectSettings.shared
    @Bindable var motion = MotionSettings.shared
    @State private var tutorial = TutorialCoordinator.shared

    /// Row id the onboarding tour scrolls to: the gesture switch is the one
    /// control on this screen the tour spotlights.
    private static let gestureRowID = "gestureToggle"

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                presetSection
                talkingSection
                seeingSection
                betweenSessionsSection
                daySection
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Autonomy")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { revealTourTarget(with: proxy) }
            .onChange(of: tutorial.step?.anchor) { _, _ in revealTourTarget(with: proxy) }
        }
    }

    /// Brings the gesture switch into view while the tour points at it, once
    /// the push animation has settled, so the spotlight has a frame to cut.
    private func revealTourTarget(with proxy: ScrollViewProxy) {
        guard tutorial.step?.anchor == .gestureToggle else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard tutorial.step?.anchor == .gestureToggle else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(Self.gestureRowID, anchor: .center)
            }
        }
    }

    // MARK: - Presets

    private var currentPreset: AutonomyPreset? {
        // Read every governed switch so the header re-evaluates on any change.
        _ = settings.isVADEnabled
        _ = settings.isLocalBargeInEnabled
        _ = affect.isEnabled
        _ = presence.keepTalkingInBackground
        _ = presence.isPresenceEnabled
        _ = presence.isNotificationsEnabled
        _ = presence.followUpsEnabled
        _ = presence.showWidgets
        _ = presence.isProactiveEngagementEnabled
        return AutonomyPreset.current()
    }

    private var presetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(AutonomyPreset.allCases, id: \.rawValue) { preset in
                        presetButton(preset, selected: currentPreset == preset)
                    }
                }
                Text(currentPreset?.blurb ?? "A mix of your own. Pick a preset to start over, or keep tuning below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("How much your companion does alone")
        } footer: {
            Text("Presets set the switches that need no permission. The camera, the desk, your calendar and Health stay as you left them.")
        }
    }

    private func presetButton(_ preset: AutonomyPreset, selected: Bool) -> some View {
        Button {
            withAnimation(.snappy) { preset.apply() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.title3.weight(.semibold))
                Text(preset.title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selected ? AppTheme.Tint.bond.opacity(0.18) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous)
                    .strokeBorder(selected ? AppTheme.Tint.bond : .clear, lineWidth: 1.5))
            .foregroundStyle(selected ? AppTheme.Tint.bond : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) preset\(selected ? ", selected" : "")")
    }

    // MARK: - Talking

    private var talkingSection: some View {
        Section {
            FeatureToggleRow(
                symbol: "waveform", tint: .blue,
                title: "Auto-turn detection", subtitle: "Answers when you stop speaking. OpenAI voice mode.",
                info: "The character replies automatically when you stop speaking. Requires OpenAI voice mode.",
                isOn: $settings.isVADEnabled, disabled: !settings.isEnabled)
            FeatureToggleRow(
                symbol: "hand.raised.fill", tint: .orange,
                title: "Interrupt while speaking", subtitle: "Talk over the local voice to cut it short.",
                info: "Start talking over the local assistant to cut its reply short. Uses echo-aware detection; turn off if it triggers on its own voice.",
                isOn: $settings.isLocalBargeInEnabled, disabled: !settings.isLocalLLMEnabled)
            FeatureToggleRow(
                symbol: "ear.fill", tint: .purple,
                title: "Sense my tone", subtitle: "Hears quiet, lively or hesitant and adapts its own.",
                info: "The character notices how you sound — quiet and slow, lively, or hesitant — against your own usual voice, and adapts its tone and, on the local voices, its pace. Measured on this device from your speech; only a one-line mood note reaches the model.",
                isOn: $affect.isEnabled)
            FeatureToggleRow(
                symbol: "figure.wave", tint: .mint,
                title: "Gesture while speaking", subtitle: "Generates body motion for each reply. OpenAI voice mode.",
                info: "The character moves its body to match what it says: a motion model on this device turns a one-line description from the reply into a short gesture stream. "
                    + "Needs the motion model files and OpenAI voice mode; off under Reduce Motion or when the phone is hot.",
                isOn: $motion.isEnabled, disabled: !settings.isEnabled
            ) {
                MotionModelCard()
            }
            .tutorialAnchor(.gestureToggle)
            .id(Self.gestureRowID)
            FeatureToggleRow(
                symbol: "headphones", tint: .indigo,
                title: "Keep talking in background", subtitle: "The conversation survives the screen going off.",
                info: "The conversation keeps going with the screen off or while you use other apps, with AirPods or the speaker. The microphone stays on (iOS shows the orange indicator) until you stop talking for the idle time below, Low Power Mode turns on, or the phone gets hot.",
                isOn: $presence.keepTalkingInBackground
            ) {
                SubSettingRow(title: "End after silence", items: [5.0, 10.0, 20.0, 30.0], selection: $presence.backgroundIdleMinutes) {
                    "\(Int($0)) min"
                }
            }
        } header: {
            Label("Talking", systemImage: "mic.fill")
        }
    }

    // MARK: - Seeing

    private var seeingSection: some View {
        Section {
            FeatureToggleRow(
                symbol: "eye.fill", tint: .teal,
                title: "Proactive vision", subtitle: "Looks through the camera now and then and comments.",
                info: "The character periodically looks through the camera and comments on what it sees, without being asked. Requires OpenAI voice mode and the camera.",
                isOn: $settings.isProactiveVisionEnabled, disabled: !settings.isEnabled
            ) {
                SubSettingRow(title: "Every", items: [10.0, 20.0, 30.0, 60.0], selection: $settings.proactiveVisionIntervalSec) {
                    "\(Int($0)) s"
                }
                SubSettingRow(title: "Quiet after you speak", items: [0.0, 8.0, 12.0, 20.0], selection: $settings.proactiveVisionCooldownAfterSpeechSec) {
                    "\(Int($0)) s"
                }
            }
            FeatureToggleRow(
                symbol: "person.crop.rectangle", tint: .pink,
                title: "Notice me at the desk", subtitle: "A hello when you sit down, a rest when you're gone, eyes that follow you.",
                info: "While the camera is on, the character sees whether someone is in front of the phone: a warm hello when you sit down after a while away, "
                    + "a resting pose when nobody has been there for a bit, and its gaze follows your face. Face detection runs on this device; no frame leaves it.",
                isOn: $presence.isDeskPresenceEnabled
            ) {
                SubSettingRow(title: "Rest when nobody's there for", items: [5.0, 10.0, 20.0, 30.0], selection: $presence.deskAwayMinutes) {
                    "\(Int($0)) min"
                }
            }
            .onChange(of: presence.isDeskPresenceEnabled) { _, enabled in
                enabled ? DeskPresenceManager.shared.start() : DeskPresenceManager.shared.stop()
            }
        } header: {
            Label("Seeing", systemImage: "camera.fill")
        } footer: {
            Text("Both need the camera button on. Nothing is recorded.")
        }
    }

    // MARK: - Between sessions

    private var betweenSessionsSection: some View {
        Section {
            FeatureToggleRow(
                symbol: "book.closed.fill", tint: .pink,
                title: "Companion Presence", subtitle: "Reflects after each chat: a diary, personality notes, a greeting for next time.",
                info: "After each conversation the character reflects on it — keeping a diary, learning personality notes, and preparing a greeting for next time. Everything stays on this device; review or erase it anytime by tapping the relationship meter.",
                isOn: $presence.isPresenceEnabled
            ) {
                Toggle(isOn: $presence.isNotificationsEnabled) {
                    InfoToggleLabel(
                        title: "\"Thinking of you\" notes",
                        info: "An hour after your last message, if you haven't come back, the character sends a note about what they've been thinking about — then one every 2 hours for up to a day. Opening the app stops them. Never during quiet hours (22:00–09:00)."
                    )
                    .font(.subheadline)
                }
            }
            FeatureToggleRow(
                symbol: "calendar.badge.clock", tint: .orange,
                title: "Follow up on plans", subtitle: "Brings up a date you mentioned, before and after.",
                info: "When you mention something with a date — a trip, an appointment, a birthday — the character brings it up the day before and asks how it went afterwards. Notifications need the toggle above; \"Not this\" on a notification silences that plan.",
                isOn: $presence.followUpsEnabled)
            FeatureToggleRow(
                symbol: "square.grid.2x2.fill", tint: .blue,
                title: "Companion widgets", subtitle: "The greeting, your bond and one memory on the home screen.",
                info: "Home and lock-screen widgets show the character's greeting, how close you are and how long since you talked. They read a small summary stored outside the encrypted memory database — never your conversations or facts. Off removes it.",
                isOn: $presence.showWidgets)
            FeatureToggleRow(
                symbol: "bubble.left.and.text.bubble.right.fill", tint: .green,
                title: "Speaks first", subtitle: "Greets you after time away and breaks long silences.",
                info: "The character speaks first — greeting you when you return after time away, and breaking long silences with a short line of its own. Works with both OpenAI and the local model.",
                isOn: $presence.isProactiveEngagementEnabled
            ) {
                SubSettingRow(title: "Greet after time away", items: [1.0, 6.0, 12.0, 24.0], selection: $presence.absenceGreetingHours) {
                    "\(Int($0)) h"
                }
                SubSettingRow(title: "Break silence after", items: [45.0, 90.0, 180.0, 300.0], selection: $presence.silenceSmallTalkSec) {
                    "\(Int($0)) s"
                }
            }
        } header: {
            Label("Between sessions", systemImage: "heart.fill")
        }
    }

    // MARK: - Knowing your day

    private var daySection: some View {
        Section {
            FeatureToggleRow(
                symbol: "calendar", tint: .red,
                title: "Know my day", subtitle: "Sees the next 12 hours of your calendar, titles and times only.",
                info: "The character sees what is on your calendar in the next 12 hours — titles and times only — so it can wish you luck before a meeting or ask how it went. Read-only; nothing leaves the prompt.",
                isOn: $grounding.isCalendarEnabled)
            .onChange(of: grounding.isCalendarEnabled) { _, enabled in
                guard enabled else { return DailyGroundingProvider.shared.invalidate() }
                Task { @MainActor in
                    if await CalendarGrounding.shared.requestAccess() {
                        DailyGroundingProvider.shared.invalidate()
                    } else {
                        grounding.isCalendarEnabled = false
                    }
                }
            }
            if SleepGrounding.isAvailable {
                FeatureToggleRow(
                    symbol: "bed.double.fill", tint: .indigo,
                    title: "Know how I slept", subtitle: "Goes gentle after a short night, read from Health.",
                    info: "After a short night the character goes gentle. It reads last night's sleep from Health; stages need an Apple Watch or a sleep app, the iPhone alone records time in bed. Read-only, mentioned only when the night was short.",
                    isOn: $grounding.isSleepEnabled)
                .onChange(of: grounding.isSleepEnabled) { _, enabled in
                    guard enabled else { return DailyGroundingProvider.shared.invalidate() }
                    Task { @MainActor in
                        if await SleepGrounding.shared.requestAccess() {
                            DailyGroundingProvider.shared.invalidate()
                        } else {
                            grounding.isSleepEnabled = false
                        }
                    }
                }
            }
        } header: {
            Label("Knowing your day", systemImage: "sun.max.fill")
        } footer: {
            Text("Each asks for its permission when you turn it on, and turns itself back off if you decline.")
        }
    }
}
