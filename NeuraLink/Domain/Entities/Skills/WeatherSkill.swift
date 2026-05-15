//
//  WeatherSkill.swift
//  NeuraLink
//
//  Fetches current weather via Open-Meteo (no API key required).
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation

@MainActor
final class WeatherSkill: Skill {
    static let toolName = AppFunctionTool.getWeather
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        let location = arguments["location"] as? String ?? "unknown"
        return await fetchWeather(for: location)
    }

    // MARK: - Implementation

    private func fetchWeather(for location: String) async -> String {
        guard let geoURL = URL(
            string: "https://geocoding-api.open-meteo.com/v1/search?name=\(location.urlEncoded)&count=1&language=en&format=json"
        ) else { return "Could not build geocoding request." }

        do {
            let (geoData, _) = try await URLSession.shared.data(from: geoURL)
            guard
                let geoJSON = try JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                let results  = geoJSON["results"] as? [[String: Any]],
                let first    = results.first,
                let lat      = first["latitude"]  as? Double,
                let lon      = first["longitude"] as? Double,
                let name     = first["name"]      as? String
            else { return "I couldn't find a location called \"\(location)\"." }

            let urlStr =
                "https://api.open-meteo.com/v1/forecast"
                + "?latitude=\(lat)&longitude=\(lon)"
                + "&current=temperature_2m,apparent_temperature,precipitation,rain,"
                + "weather_code,wind_speed_10m,relative_humidity_2m"
                + "&temperature_unit=celsius&wind_speed_unit=kmh&timezone=auto"

            guard let weatherURL = URL(string: urlStr) else {
                return "Could not build weather request."
            }
            let (weatherData, _) = try await URLSession.shared.data(from: weatherURL)
            guard
                let json    = try JSONSerialization.jsonObject(with: weatherData) as? [String: Any],
                let current = json["current"] as? [String: Any]
            else { return "Weather data unavailable for \(name)." }

            let temp      = current["temperature_2m"]      as? Double ?? 0
            let feelsLike = current["apparent_temperature"] as? Double ?? 0
            let humidity  = current["relative_humidity_2m"] as? Int    ?? 0
            let windSpeed = current["wind_speed_10m"]       as? Double ?? 0
            let rain      = current["rain"]                 as? Double ?? 0
            let code      = current["weather_code"]         as? Int    ?? 0
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

    /// Maps WMO weather code → human-readable description.
    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0:        return "clear sky"
        case 1:        return "mainly clear"
        case 2:        return "partly cloudy"
        case 3:        return "overcast"
        case 45, 48:   return "foggy"
        case 51...55:  return "drizzle"
        case 61...65:  return "rainy"
        case 66, 67:   return "freezing rain"
        case 71...75:  return "snowfall"
        case 77:       return "snow grains"
        case 80...82:  return "rain showers"
        case 85, 86:   return "snow showers"
        case 95:       return "thunderstorm"
        case 96, 99:   return "thunderstorm with hail"
        default:       return "mixed conditions"
        }
    }
}
