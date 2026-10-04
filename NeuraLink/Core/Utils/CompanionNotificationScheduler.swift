//
//  CompanionNotificationScheduler.swift
//  NeuraLink
//
//  Local "your companion has been thinking of you" notifications — Living
//  Companion (docs/LIVING_COMPANION.md). Rules, enforced here:
//    • a return series: the first 1 h after the last exchange, then one
//      every 2 h while the app stays closed, for at most 24 h — scheduled
//      up front, because iOS cannot run the app to compose one later,
//    • never delivered during quiet hours (22:00–09:00 local — a slot that
//      lands there moves to the next 09:30 and the rhythm resumes from it),
//    • the whole series is cancelled the moment the user returns.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation
import Intents
import UIKit
import UserNotifications

/// Lets local notifications present as banners while the app is FOREGROUND
/// (iOS suppresses them otherwise) — `.list` also makes them persist in the
/// Notification Center / lock screen. Real presence notifications are
/// cancelled on foreground anyway; this matters for debug-delay test runs
/// (`-nl.debug.presenceNotifDelaySec`) where one can fire with the app open.
final class CompanionNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompanionNotificationPresenter()

    /// Installs self as the notification-center delegate. Idempotent.
    func install() {
        UNUserNotificationCenter.current().delegate = self
        CompanionNotificationScheduler.registerCategories()
    }

    /// "Not this" on a follow-up mutes that fact for good.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == CompanionNotificationScheduler.followUpMuteAction,
           let unitID = info[CompanionNotificationScheduler.followUpUnitKey] as? Int64 {
            Task { @MainActor in MemoryStore.shared.muteFollowUps(unitID: unitID) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // `.list` matters: without it a foreground-presented notification
        // vanishes after the banner instead of persisting in the
        // Notification Center / lock screen like every other notification.
        completionHandler([.banner, .list, .sound])
    }
}

enum CompanionNotificationScheduler {

    /// Series slots use "\(identifier).<seriesID>.<slot>".
    static let identifier = "com.neuralink.presence.reflection"
    static let recapIdentifier = "com.neuralink.presence.recap"
    static let followUpIdentifier = "com.neuralink.presence.followup"
    static let followUpCategory = "NL_FOLLOWUP"
    static let followUpMuteAction = "NL_FOLLOWUP_MUTE"
    static let followUpUnitKey = "unitID"

    /// Registers the follow-up category ("Not this" action). Idempotent.
    static func registerCategories() {
        let mute = UNNotificationAction(identifier: followUpMuteAction, title: "Not this", options: [])
        let category = UNNotificationCategory(identifier: followUpCategory, actions: [mute], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Schedules one follow-up notification at `fireAt` (replacing any
    /// pending one). Returns false when not authorized or the add fails.
    static func scheduleFollowUp(characterName: String, body: String, unitID: Int64, fireAt: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [followUpIdentifier])

        let name = characterName.trimmingCharacters(in: .whitespaces)
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "Your companion" : name.capitalized
        content.body = body
        content.sound = .default
        content.categoryIdentifier = followUpCategory
        content.userInfo = [followUpUnitKey: unitID]
        let finalContent = communicationContent(base: content, characterName: name)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, fireAt.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: followUpIdentifier, content: finalContent, trigger: trigger))
            nlLog("[FollowUp] notification scheduled for \(fireAt)", level: .info)
            return true
        } catch {
            nlLog("[FollowUp] failed to schedule: \(error)", level: .warning)
            return false
        }
    }

    /// Return series timing.
    static let firstDelay: TimeInterval = 3600
    static let repeatInterval: TimeInterval = 2 * 3600
    static let seriesWindow: TimeInterval = 24 * 3600
    static let maxSeriesCount = 12

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
    /// `-nl.debug.presenceNotifDelaySec 60`): first delivery in N seconds,
    /// then every 2N, quiet hours bypassed — the series is testable without
    /// waiting hours.
    static let debugDelayKey = "nl.debug.presenceNotifDelaySec"

    struct Timing: Equatable {
        var first: TimeInterval
        var interval: TimeInterval
        var clampQuietHours: Bool
    }

    static func effectiveTiming(defaults: UserDefaults = .standard) -> Timing {
        let override = defaults.double(forKey: debugDelayKey)
        guard override > 0 else { return Timing(first: firstDelay, interval: repeatInterval, clampQuietHours: true) }
        return Timing(first: override, interval: override * 2, clampQuietHours: false)
    }

    /// Fire dates for one return series anchored on the last exchange: the
    /// first `timing.first` after it (never sooner than a minute from now),
    /// then every `timing.interval`, each moved out of quiet hours, until
    /// `seriesWindow` after the first or `maxSeriesCount` slots.
    static func returnSeriesDates(
        anchor: Date, now: Date, timing: Timing, calendar: Calendar = .current
    ) -> [Date] {
        let minimumLead: TimeInterval = timing.clampQuietHours ? 60 : 10
        func place(_ date: Date) -> Date {
            timing.clampQuietHours ? clampedFireDate(now: date, delay: 0, calendar: calendar) : date
        }
        var next = place(max(anchor.addingTimeInterval(timing.first), now.addingTimeInterval(minimumLead)))
        let end = next.addingTimeInterval(seriesWindow)
        var dates: [Date] = []
        while next <= end, dates.count < maxSeriesCount {
            dates.append(next)
            next = place(next.addingTimeInterval(timing.interval))
        }
        return dates
    }

    /// Replaces any pending series with one built from `lines` (cycled when
    /// the series is longer). Returns how many were scheduled — 0 when
    /// permission is missing.
    static func scheduleReturnSeries(characterName: String, lines: [String], anchor: Date) async -> Int {
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
            return 0
        }
        guard !lines.isEmpty else { return 0 }
        // Awaited removal + a fresh id per series: removals run
        // asynchronously, so reusing ids let a late removal delete the
        // requests just added.
        await removePending(center: center)

        let timing = effectiveTiming()
        let dates = returnSeriesDates(anchor: anchor, now: Date(), timing: timing)
        let name = characterName.trimmingCharacters(in: .whitespaces)
        let avatar = name.isEmpty ? nil : avatarImageData(for: name)
        let seriesID = Int(Date().timeIntervalSince1970)
        var scheduled = 0
        for (slot, fireDate) in dates.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = name.isEmpty
                ? "Your companion has been thinking of you"
                : "\(name.capitalized) has been thinking of you"
            content.body = lines[slot % lines.count]
            content.sound = .default
            content.threadIdentifier = identifier
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(identifier).\(seriesID).\(slot)",
                content: communicationContent(base: content, characterName: name, avatar: avatar), trigger: trigger)
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                nlLog("[Presence] Failed to schedule slot \(slot): \(error)", level: .warning)
            }
        }
        let first = dates.first.map { "\($0)" } ?? "none"
        nlLog("[Presence] Return series: \(scheduled) scheduled, first \(first)\(timing.clampQuietHours ? "" : " (DEBUG timing)")",
              level: .info)
        return scheduled
    }

    /// One-off notification (the weekly recap), on its own identifier so it
    /// never replaces the return series. Delivered after `firstDelay`, out
    /// of quiet hours.
    static func schedule(characterName: String, body: String) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        center.removePendingNotificationRequests(withIdentifiers: [recapIdentifier])

        let name = characterName.trimmingCharacters(in: .whitespaces)
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? "Your companion" : name.capitalized
        content.body = body
        content.sound = .default
        let timing = effectiveTiming()
        let fireDate = returnSeriesDates(anchor: Date(), now: Date(), timing: timing).first
            ?? Date().addingTimeInterval(timing.first)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(10, fireDate.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(
                identifier: recapIdentifier,
                content: communicationContent(base: content, characterName: name), trigger: trigger))
            return true
        } catch {
            nlLog("[Presence] Failed to schedule notification: \(error)", level: .warning)
            return false
        }
    }

    // NOTE: the settings-screen "Send test notification" button was removed
    // 2026-09-11 once delivery/avatar were verified on device. For future
    // pipeline testing, use the `-nl.debug.presenceNotifDelaySec 60` launch
    // argument (see `effectiveTiming`) and background the app after a chat.

    /// One log line answering "what's the notification state right now":
    /// permission status + the pending fire date, if any. Called at launch
    /// (before the stale-cancel) and after scheduling.
    static func logDiagnostics(context: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            let series = await center.pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(identifier) }
                .compactMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }
                .sorted()
            nlLog(
                "[Presence] Notification state (\(context)): permission=\(status.rawValue) "
                    + "(2=denied, 3=authorized), pending=\(series.count), next=\(series.first.map { "\($0)" } ?? "none")",
                level: .info)
        }
    }

    // MARK: - Communication-style avatar (circular, replaces the app icon)

    /// Rebuilds `base` as a COMMUNICATION notification whose sender is the
    /// character — iOS then renders her thumbnail as a circular avatar in
    /// place of the app icon, Messages-style (the Grok Companion / Animates
    /// look). Requires the com.apple.developer.usernotifications.communication
    /// entitlement (NeuraLink.entitlements); without it the system quietly
    /// falls back to the app icon. Returns `base` untouched when the
    /// character has no thumbnail or the intent rewrite fails.
    static func communicationContent(
        base: UNMutableNotificationContent, characterName: String, avatar: Data? = nil
    ) -> UNNotificationContent {
        let name = characterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let imageData = avatar ?? avatarImageData(for: name) else { return base }

        let slug = name.lowercased()
        let sender = INPerson(
            personHandle: INPersonHandle(value: "neuralink-companion-\(slug)", type: .unknown),
            nameComponents: nil,
            displayName: name.capitalized,
            image: INImage(imageData: imageData),
            contactIdentifier: nil,
            customIdentifier: "neuralink-companion-\(slug)"
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: base.body,
            speakableGroupName: nil,
            conversationIdentifier: "neuralink-companion-\(slug)",
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        // The INPerson image alone is NOT reliably picked up for the avatar —
        // Apple's reference flow sets it on the sender parameter explicitly.
        intent.setImage(INImage(imageData: imageData), forParameterNamed: \.sender)

        // Incoming-message donation is what unlocks the sender-avatar layout.
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        do {
            return try base.updating(from: intent)
        } catch {
            nlLog("[Presence] Communication-style rewrite failed: \(error)", level: .warning)
            return base
        }
    }

    /// The character's thumbnail PNG — same next-to-model convention as the
    /// settings persona row.
    static func characterThumbnailData(for characterName: String) -> Data? {
        guard let entry = VRMModelRegistry.shared.all
            .first(where: { $0.name.lowercased() == characterName.lowercased() })
        else { return nil }
        let png = entry.url.deletingPathExtension().appendingPathExtension("png")
        return try? Data(contentsOf: png)
    }

    /// The thumbnail rendered onto an opaque backdrop with a light ring —
    /// many VRM thumbnails have transparent backgrounds, which read as a
    /// shapeless cutout inside the system's circular avatar mask. Backdrop:
    /// the app's dark glassy gradient; ring inset enough to survive the mask.
    static func avatarImageData(for characterName: String) -> Data? {
        guard let raw = characterThumbnailData(for: characterName),
            let image = UIImage(data: raw)
        else { return nil }

        let size = CGSize(width: 512, height: 512)
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)

            // Backdrop gradient (slate → near-black).
            let colors = [
                UIColor(red: 0.17, green: 0.22, blue: 0.32, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero,
                    end: CGPoint(x: 0, y: size.height), options: [])
            }

            // Character as big as the circle allows: aspect-fit with a slight
            // overscan (crops a hair of the portrait, reads much larger). The
            // upward bias keeps faces in frame when the vertical crop bites;
            // the ring drawn after simply overlaps the image edge, framing it.
            let zoom: CGFloat = 1.18
            let scale = min(size.width / image.size.width, size.height / image.size.height) * zoom
            let drawSize = CGSize(
                width: image.size.width * scale, height: image.size.height * scale)
            let overflowY = max(0, drawSize.height - size.height)
            image.draw(in: CGRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2 - overflowY * 0.30,
                width: drawSize.width, height: drawSize.height))

            // Ring border, drawn inside the future circular mask.
            let ringWidth = size.width * 0.035
            context.cgContext.setStrokeColor(UIColor(white: 1.0, alpha: 0.85).cgColor)
            context.cgContext.setLineWidth(ringWidth)
            context.cgContext.strokeEllipse(in: rect.insetBy(dx: ringWidth, dy: ringWidth))
        }
        return rendered.pngData()
    }

    /// The whole pending "come back" series (and recap) is stale the moment
    /// the user is back. Matched by prefix, so every series id (and those
    /// from older builds) goes.
    static func cancelPending() {
        Task { await removePending(center: UNUserNotificationCenter.current()) }
    }

    private static func removePending(center: UNUserNotificationCenter) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifier) || $0 == recapIdentifier }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
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
