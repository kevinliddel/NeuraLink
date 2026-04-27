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

    private init() {}

    // MARK: - Dispatch

    /// Executes a named tool call and returns a plain-text result for the AI.
    func execute(name: String, arguments: [String: Any]) async -> String {
        switch name {
        case AppFunctionTool.getWeather:
            let location = arguments["location"] as? String ?? "unknown"
            return await fetchWeather(for: location)

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

        default:
            return "Unknown function: \(name)"
        }
    }

    // MARK: - Weather (Open-Meteo, no API key required)

    private func fetchWeather(for location: String) async -> String {
        // Step 1: Geocode
        guard
            let geoURL = URL(
                string:
                    "https://geocoding-api.open-meteo.com/v1/search?name=\(location.urlEncoded)&count=1&language=en&format=json"
            )
        else { return "Could not build geocoding request." }

        do {
            let (geoData, _) = try await URLSession.shared.data(from: geoURL)
            guard
                let geoJSON = try JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                let results = geoJSON["results"] as? [[String: Any]],
                let first = results.first,
                let lat = first["latitude"] as? Double,
                let lon = first["longitude"] as? Double,
                let name = first["name"] as? String
            else {
                return "I couldn't find a location called \"\(location)\"."
            }

            // Step 2: Fetch weather
            let weatherURLStr =
                "https://api.open-meteo.com/v1/forecast"
                + "?latitude=\(lat)&longitude=\(lon)"
                + "&current=temperature_2m,apparent_temperature,precipitation,rain,"
                + "weather_code,wind_speed_10m,relative_humidity_2m"
                + "&temperature_unit=celsius&wind_speed_unit=kmh&timezone=auto"

            guard let weatherURL = URL(string: weatherURLStr) else {
                return "Could not build weather request."
            }

            let (weatherData, _) = try await URLSession.shared.data(from: weatherURL)
            guard
                let json = try JSONSerialization.jsonObject(with: weatherData) as? [String: Any],
                let current = json["current"] as? [String: Any]
            else {
                return "Weather data unavailable for \(name)."
            }

            let temp = current["temperature_2m"] as? Double ?? 0
            let feelsLike = current["apparent_temperature"] as? Double ?? 0
            let humidity = current["relative_humidity_2m"] as? Int ?? 0
            let windSpeed = current["wind_speed_10m"] as? Double ?? 0
            let rain = current["rain"] as? Double ?? 0
            let code = current["weather_code"] as? Int ?? 0

            let condition = weatherDescription(for: code)

            return """
                Current weather in \(name): \(condition). \
                Temperature \(Int(temp))°C, feels like \(Int(feelsLike))°C. \
                Humidity \(humidity)%, wind \(Int(windSpeed)) km/h\
                \(rain > 0 ? ", rain \(rain) mm" : "").
                """
        } catch {
            return "Failed to fetch weather: \(error.localizedDescription)"
        }
    }

    /// Maps WMO weather code to human-readable description.
    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzle"
        case 61, 63, 65: return "rainy"
        case 66, 67: return "freezing rain"
        case 71, 73, 75: return "snowfall"
        case 77: return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "mixed conditions"
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
        UIApplication.shared.open(url)
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
                UIApplication.shared.open(url)
                return "Searching Apple Music for \"\(query)\"."
            }
        }
        // Fallback: open Music app root
        if let url = URL(string: "music://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
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
        // Encode title and body into a Bear/GoodNotes-style URL if available,
        // otherwise open the stock Notes app with a pre-filled x-callback-url.
        let combined = "\(title)\n\n\(body)"
        let encoded = combined.urlEncoded

        // Try Bear first (popular rich-text notes app)
        if let bearURL = URL(
            string: "bear://x-callback-url/create?title=\(title.urlEncoded)&text=\(body.urlEncoded)"
        ),
            UIApplication.shared.canOpenURL(bearURL) {
            UIApplication.shared.open(bearURL)
            return "Created a new note titled \"\(title)\" in Bear."
        }

        // Apple Notes doesn't have a public create URL scheme with body pre-fill,
        // so paste via UIPasteboard and open the app.
        UIPasteboard.general.string = combined
        if let notesURL = URL(string: "mobilenotes://"),
            UIApplication.shared.canOpenURL(notesURL) {
            UIApplication.shared.open(notesURL)
            return "Opened Notes. I've copied your note to the clipboard — paste it in a new note!"
        }

        // Last resort: share sheet
        return "I've copied the note content to your clipboard. Open Notes and paste to create it."
    }

    // MARK: - Open App

    private func openApp(named app: String) -> String {
        let schemeMap: [String: String] = [
            "Maps": "maps://",
            "Photos": "photos-redirect://",
            "Calendar": "calshow://",
            "Settings": "App-Prefs:Root=General",
            "Camera": "camera://",
            "Clock": "clock-alarm://",
            "Health": "x-apple-health://",
            "FaceTime": "facetime://"
        ]
        guard let scheme = schemeMap[app],
            let url = URL(string: scheme),
            UIApplication.shared.canOpenURL(url)
        else {
            // Fallback: open Settings to allow user to find the app
            return "I wasn't able to open \(app) directly. Please launch it from your home screen."
        }
        UIApplication.shared.open(url)
        return "Opening \(app) for you."
    }
}

// MARK: - String helper

extension String {
    fileprivate var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
