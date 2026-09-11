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
        let finalContent = communicationContent(base: content, characterName: name)

        let (delay, clamp) = effectiveDelay()
        let fireDate = clamp
            ? clampedFireDate(now: Date(), delay: delay)
            : Date().addingTimeInterval(delay)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(clamp ? 60 : 10, fireDate.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: finalContent, trigger: trigger)

        do {
            try await center.add(request)
            nlLog("[Presence] Notification scheduled for \(fireDate)\(clamp ? "" : " (DEBUG delay)")", level: .info)
            return true
        } catch {
            nlLog("[Presence] Failed to schedule notification: \(error)", level: .warning)
            return false
        }
    }

    // NOTE: the settings-screen "Send test notification" button was removed
    // 2026-09-11 once delivery/avatar were verified on device. For future
    // pipeline testing, use the `-nl.debug.presenceNotifDelaySec 60` launch
    // argument (see `effectiveDelay`) and end a ≥4-turn session.

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

    // MARK: - Communication-style avatar (circular, replaces the app icon)

    /// Rebuilds `base` as a COMMUNICATION notification whose sender is the
    /// character — iOS then renders her thumbnail as a circular avatar in
    /// place of the app icon, Messages-style (the Grok Companion / Animates
    /// look). Requires the com.apple.developer.usernotifications.communication
    /// entitlement (NeuraLink.entitlements); without it the system quietly
    /// falls back to the app icon. Returns `base` untouched when the
    /// character has no thumbnail or the intent rewrite fails.
    static func communicationContent(
        base: UNMutableNotificationContent, characterName: String
    ) -> UNNotificationContent {
        let name = characterName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let imageData = avatarImageData(for: name) else { return base }

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
