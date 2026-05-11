//
//  ReminderSkill.swift
//  NeuraLink
//
//  Creates a reminder in the Reminders app via EventKit.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation
import EventKit

@MainActor
final class ReminderSkill: Skill {
    static let toolName = AppFunctionTool.createReminder
    var pendingUIAction: (() -> Void)?
    
    private let eventStore = EKEventStore()

    func execute(arguments: [String: Any]) async -> String {
        let title = arguments["title"] as? String ?? "Reminder"
        let notes = arguments["notes"] as? String
        return await createReminder(title: title, notes: notes)
    }

    private func createReminder(title: String, notes: String?) async -> String {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else {
            return "I need permission to access Reminders. Please enable it in Settings."
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        do {
            try eventStore.save(reminder, commit: true)
            return "Done! I've added \"\(title)\" to your Reminders."
        } catch {
            return "I couldn't save the reminder: \(error.localizedDescription)"
        }
    }
}
