//
//  AppFunctionExecutor.swift
//  NeuraLink
//
//  Executes iOS function calls requested by the AI.
//  Each function fetches real data (weather) or triggers OS actions (open app,
//  play music, create reminder/note) and returns a result string for the AI to
//  incorporate into its spoken response.
//
//  Created by Dedicatus on 27/04/2026.
//

import EventKit
import Foundation
import UIKit

@MainActor
final class AppFunctionExecutor {

    static let shared = AppFunctionExecutor()
    private let eventStore = EKEventStore()
    private let settings = OpenAISettings.shared

    /// UI action (app open) stored here instead of firing immediately.
    /// Executed by OpenAIRealtimeManager after the AI finishes speaking the result.
    var pendingUIAction: (() -> Void)?

    private init() {}

    // MARK: - Dispatch

    /// Executes a named tool call and returns a plain-text result for the AI.
    func execute(name: String, arguments: [String: Any]) async -> String {
        switch name {
        case AppFunctionTool.getWeather:
            return await WeatherSkill().execute(arguments: arguments)

        case AppFunctionTool.searchWeb:
            let query = arguments["query"] as? String ?? ""
            return openSafari(query: query)

        case AppFunctionTool.playMusic:
            let query = arguments["query"] as? String ?? ""
            return openMusic(query: query)

        case AppFunctionTool.createReminder:
            let title = arguments["title"] as? String ?? "Reminder"
            let notes = arguments["notes"] as? String
            return await createReminder(title: title, notes: notes)

        case AppFunctionTool.createNote:
            let title = arguments["title"] as? String ?? "Note"
            let body = arguments["body"] as? String ?? ""
            return openNotes(title: title, body: body)

        case AppFunctionTool.openApp:
            let app = arguments["app"] as? String ?? ""
            return openApp(named: app)

        case AppFunctionTool.analyzeCamera:
            let prompt = arguments["prompt"] as? String
            return await analyzeCamera(prompt: prompt)

        default:
            return "Unknown function: \(name)"
        }
    }


    // MARK: - Safari

    private func openSafari(query: String) -> String {
        let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
        let urlString: String
        if isURL {
            urlString = query
        } else {
            let encoded = query.urlEncoded
            urlString = "https://www.google.com/search?q=\(encoded)"
        }
        guard let url = URL(string: urlString) else {
            return "Could not open Safari for: \(query)"
        }
        pendingUIAction = { UIApplication.shared.open(url) }
        return "Opened Safari to search for \"\(query)\"."
    }

    // MARK: - Apple Music

    private func openMusic(query: String) -> String {
        // music:// deep link to search in Apple Music
        let encoded = query.urlEncoded
        let schemes: [String] = [
            "music://music.apple.com/search?term=\(encoded)",
            "https://music.apple.com/search?term=\(encoded)"
        ]
        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                pendingUIAction = { UIApplication.shared.open(url) }
                return "Searching Apple Music for \"\(query)\"."
            }
        }
        // Fallback: open Music app root
        if let url = URL(string: "music://"), UIApplication.shared.canOpenURL(url) {
            pendingUIAction = { UIApplication.shared.open(url) }
            return "Opened Apple Music. You can search for \"\(query)\" there."
        }
        return "Apple Music doesn't appear to be available on this device."
    }

    // MARK: - Reminders (EventKit)

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

    // MARK: - Notes

    private func openNotes(title: String, body: String) -> String {
        let combined = "\(title)\n\n\(body)"

        // Try Bear first (popular rich-text notes app)
        if let bearURL = URL(
            string: "bear://x-callback-url/create?title=\(title.urlEncoded)&text=\(body.urlEncoded)"
        ),
            UIApplication.shared.canOpenURL(bearURL) {
            pendingUIAction = { UIApplication.shared.open(bearURL) }
            return "Created a new note titled \"\(title)\" in Bear."
        }

        UIPasteboard.general.string = combined
        if let notesURL = URL(string: "mobilenotes://"),
            UIApplication.shared.canOpenURL(notesURL) {
            pendingUIAction = { UIApplication.shared.open(notesURL) }
            return "Opened Notes. I've copied your note to the clipboard — paste it in a new note!"
        }

        return "I've copied the note content to your clipboard. Open Notes and paste to create it."
    }

    // MARK: - Camera Vision

    private func analyzeCamera(prompt: String?) async -> String {
        guard CameraManager.shared.isActive else {
            return "The camera is not active. Ask the user to enable it first."
        }
        guard let image = CameraManager.shared.captureCurrentFrame() else {
            return "Could not capture a frame from the camera right now."
        }
        let description = prompt ?? "Describe what you see in this image concisely and naturally."
        return await VisionAnalyzer.analyze(
            image: image,
            prompt: description,
            apiKey: settings.apiKey
        )
    }

    // MARK: - Open App

    private func openApp(named app: String) -> String {
        // Settings uses the public API — App-Prefs: is private and triggers App Store rejection
        if app == "Settings" {
            pendingUIAction = { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            return "Opening Settings for you."
        }

        let schemeMap: [String: String] = [
            "Maps": "maps://",
            "Photos": "photos-redirect://",
            "Calendar": "calshow://",
            "Camera": "camera://",
            "Clock": "clock-alarm://",
            "Health": "x-apple-health://",
            "FaceTime": "facetime://"
        ]
        guard let scheme = schemeMap[app],
            let url = URL(string: scheme),
            UIApplication.shared.canOpenURL(url)
        else {
            return "I wasn't able to open \(app) directly. Please launch it from your home screen."
        }
        pendingUIAction = { UIApplication.shared.open(url) }
        return "Opening \(app) for you."
    }
}

// MARK: - String helper

extension String {
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
