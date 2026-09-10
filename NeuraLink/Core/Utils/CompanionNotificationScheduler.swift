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

    /// Debug override (Xcode scheme launch argument
    /// `-nl.debug.presenceNotifDelaySec 60`): delivery in N seconds with the
    /// quiet-hours clamp bypassed, so the pipeline is testable without
    /// staying away from the app for six real hours.
    static let debugDelayKey = "nl.debug.presenceNotifDelaySec"

    /// (delay, whether quiet hours apply) — the debug override skips the clamp.
    static func effectiveDelay(defaults: UserDefaults = .standard) -> (delay: TimeInterval, clampQuietHours: Bool) {
        let override = defaults.double(forKey: debugDelayKey)
        guard override > 0 else { return (defaultDelay, true) }
        return (override, false)
    }

    /// Schedules (replacing any pending) the reflection notification.
    /// Returns false when not authorized or the add fails.
    static func schedule(characterName: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            // The single most common "why did nothing arrive" answer — make
            // it loud: the toggle is on but iOS permission was never granted
            // (or was revoked in Settings → Notifications).
            nlLog(
                "[Presence] NOT scheduling — notification permission missing (status=\(status.rawValue)). "
                    + "Check Settings → Notifications → NeuraLink.",
                level: .warning)
            return false
        }

        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let name = characterName.trimmingCharacters(in: .whitespaces)
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty
            ? "Your companion has been thinking of you"
            : "\(name.capitalized) has been thinking of you"
        content.body = body
        content.sound = .default

        let (delay, clamp) = effectiveDelay()
        let fireDate = clamp
            ? clampedFireDate(now: Date(), delay: delay)
            : Date().addingTimeInterval(delay)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(clamp ? 60 : 10, fireDate.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            nlLog("[Presence] Notification scheduled for \(fireDate)\(clamp ? "" : " (DEBUG delay)")", level: .info)
            return true
        } catch {
            nlLog("[Presence] Failed to schedule notification: \(error)", level: .warning)
            return false
        }
    }

    /// One log line answering "what's the notification state right now":
    /// permission status + the pending fire date, if any. Called at launch
    /// (before the stale-cancel) and after scheduling.
    static func logDiagnostics(context: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            let pending = await center.pendingNotificationRequests()
                .first { $0.identifier == identifier }
                .flatMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }
            nlLog(
                "[Presence] Notification state (\(context)): permission=\(status.rawValue) "
                    + "(2=denied, 3=authorized), pending=\(pending.map { "\($0)" } ?? "none")",
                level: .info)
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
