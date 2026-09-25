//
//  PhotoMemoryService.swift
//  NeuraLink
//
//  Photo memories (docs/COMPANION_DEPTH_PLAN.md §D2): the user shows a
//  photo, the vision model describes it once, the companion reacts, and an
//  `experience` unit with a small on-device thumbnail is remembered. The
//  photo itself is never copied.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import ImageIO
import UIKit

extension Notification.Name {
    /// Posted by the `show_photo` tool; ContentView presents the picker.
    static let photoMemoryPickerRequested = Notification.Name("NLPhotoMemoryPickerRequested")
}

final class PhotoMemoryService {
    static let shared = PhotoMemoryService()

    static let maxPixels: CGFloat = 1_024
    static let thumbnailPixels: CGFloat = 256
    static let contextPrefix = "photo:"
    static let directoryName = "photo-memories"

    private init() {}

    // MARK: - Entry

    /// Handles a picked image: describe, react, remember.
    func handlePicked(data: Data, userWords: String) async {
        guard let image = UIImage(data: data) else { return }
        let takenAt = Self.captureDate(from: data) ?? Date()
        let scaled = Self.downscale(image, maxPixels: Self.maxPixels)
        let description = await describe(scaled, userWords: userWords)
        react(description: description, userWords: userWords)
        remember(image: scaled, description: description, userWords: userWords, takenAt: takenAt)
    }

    /// Cloud vision when available; otherwise the user's own words.
    private func describe(_ image: UIImage, userWords: String) async -> String {
        let settings = OpenAISettings.shared
        guard settings.isEnabled, settings.hasValidKey else {
            return userWords.isEmpty ? "a photo the user showed" : userWords
        }
        let prompt = "The user is showing you this photo" + (userWords.isEmpty ? "." : " and says: \"\(userWords)\".")
            + " Describe it in two short sentences, naming any people, places or events the user mentioned."
        let text = await VisionAnalyzer.analyze(image: image, prompt: prompt, apiKey: settings.apiKey)
        return text.hasPrefix("Vision error") || text.hasPrefix("Could not") ? (userWords.isEmpty ? "a photo the user showed" : userWords) : text
    }

    private func react(description: String, userWords: String) {
        let event = "[The user showed you a photo: \(description)]"
        ProactivePresenceManager.shared.engage(with: event)
    }

    private func remember(image: UIImage, description: String, userWords: String, takenAt: Date) {
        guard MemorySettings.shared.isEnabled else { return }
        let character = RealtimeChatState.shared.selectedCharacterName
        let fact = Self.fact(from: description, userWords: userWords, takenAt: takenAt, character: character)
        let fileName = Self.saveThumbnail(image)
        let id = MemoryRetain.shared.retainFact(fact, source: "photo", mentionedAt: Date())
        if id > 0, let fileName {
            MemoryStore.shared.updateContext(id: id, context: Self.contextPrefix + fileName)
        }
        OpenAIRealtimeManager.postInstructionsChanged(reason: "photo memory")
    }

    // MARK: - Pure helpers

    /// Experience fact for the memory layer.
    static func fact(from description: String, userWords: String, takenAt: Date, character: String) -> ExtractedFact {
        let who = character.isEmpty ? "the assistant" : character.capitalized
        var text = "User showed \(who) a photo: \(description.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !userWords.isEmpty { text += " User said: \"\(userWords)\"." }
        var fact = ExtractedFact(text: String(text.prefix(300)))
        fact.factType = .experience
        fact.occurredStart = takenAt
        fact.occurredEnd = takenAt
        fact.entities = MemoryFactExtraction.dedupe(
            [MemoryEntityExtractor.userEntity] + MemoryEntityExtractor.entities(in: description + " " + userWords, includeUser: false))
        return fact
    }

    /// EXIF `DateTimeOriginal` ("yyyy:MM:dd HH:mm:ss") when present.
    nonisolated static func captureDate(from data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parseExifDate(raw)
    }

    nonisolated static func parseExifDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    nonisolated static func downscale(_ image: UIImage, maxPixels: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height) * image.scale
        guard longest > maxPixels else { return image }
        let ratio = maxPixels / longest
        let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Thumbnails

    static func directoryURL() -> URL? {
        guard let base = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? ProtectedStorage.protect(dir)
        }
        return dir
    }

    /// Writes a 256 px JPEG; returns the file name.
    static func saveThumbnail(_ image: UIImage) -> String? {
        guard let dir = directoryURL() else { return nil }
        let thumb = downscale(image, maxPixels: thumbnailPixels)
        guard let data = thumb.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = dir.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? ProtectedStorage.protect(url)
        return name
    }

    /// Thumbnail file for a unit whose context carries a photo reference.
    static func thumbnailURL(for unit: MemoryUnit) -> URL? {
        guard unit.context.hasPrefix(contextPrefix) else { return nil }
        let name = String(unit.context.dropFirst(contextPrefix.count))
        guard let base = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name)
    }

    static func isPhoto(_ unit: MemoryUnit) -> Bool { unit.context.hasPrefix(contextPrefix) }
}
