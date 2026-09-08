//
//  CompanionNotificationScheduler.swift
//  NeuraLink
//
//  Local "your companion has been thinking of you" notifications — Living
//  Companion Phase 1 (docs/LIVING_COMPANION_PLAN.md). First UserNotifications
//  usage in the app. Etiquette rules, enforced here:
//    • at most ONE pending notification (same identifier → replace),
//    • never delivered during quiet hours (22:00–09:00 local — clamped to
//      the next 09:30),
//    • cancelled the moment the user returns to the app.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation
import UserNotifications

enum CompanionNotificationScheduler {

    static let identifier = "com.neuralink.presence.reflection"

    /// Default delivery delay after a session ends.
    static let defaultDelay: TimeInterval = 6 * 3600

    static let quietStartHour = 22
    static let quietEndHour = 9

    // MARK: - Authorization

    /// Alert-only authorization (no badge — the companion invites, it
    /// doesn't nag). Returns whether we may schedule.
    static func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        nlLog("[Presence] Notification authorization granted=\(granted)", level: .info)
        return granted
    }

    // MARK: - Scheduling

    /// Schedules (replacing any pending) the reflection notification.
    /// Returns false when not authorized or the add fails.
    static func schedule(
        characterName: String,
        body: String,
        after delay: TimeInterval = defaultDelay
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }

        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let name = characterName.trimmingCharacters(in: .whitespaces)
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty
            ? "Your companion has been thinking of you"
            : "\(name.capitalized) has been thinking of you"
        content.body = body
        content.sound = .default

        let fireDate = clampedFireDate(now: Date(), delay: delay)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(60, fireDate.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            nlLog("[Presence] Notification scheduled for \(fireDate)", level: .info)
            return true
        } catch {
            nlLog("[Presence] Failed to schedule notification: \(error)", level: .warning)
            return false
        }
    }

    /// A pending "come back" is stale the moment the user is back.
    static func cancelPending() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Quiet hours (pure, unit-tested)

    /// Moves a proposed fire time out of the 22:00–09:00 quiet window to the
    /// next 09:30 local. Daytime times pass through unchanged.
    static func clampedFireDate(now: Date, delay: TimeInterval, calendar: Calendar = .current) -> Date {
        let proposed = now.addingTimeInterval(delay)
        let hour = calendar.component(.hour, from: proposed)
        if hour >= quietStartHour {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: proposed) ?? proposed
            return calendar.date(bySettingHour: 9, minute: 30, second: 0, of: nextDay) ?? proposed
        }
        if hour < quietEndHour {
            return calendar.date(bySettingHour: 9, minute: 30, second: 0, of: proposed) ?? proposed
        }
        return proposed
    }
}
