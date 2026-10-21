//
//  CompanionSceneCapture.swift
//  NeuraLink
//
//  Candid pictures of the companion's world for the diary and the return
//  notifications — Companion Evolution pillar 2 (docs/LIVING_COMPANION.md).
//  Metal only draws while the scene is on screen, and the reflection runs
//  after the app has gone to the background, so instead of rendering then
//  this keeps ONE fresh capture of the live scene (every 30 s while idle,
//  and on the way to the background) that the reflection adopts.
//
//  Created by Dedicatus on 16/10/2026.
//

import UIKit
import UserNotifications

final class CompanionSceneCapture {
    static let shared = CompanionSceneCapture()

    static let directoryName = "scene-captures"
    static let latestName = "latest.jpg"
    static let interval: Duration = .seconds(30)
    static let maxPixels: CGFloat = 1_280
    /// A capture older than this is from another day in her life, not this session's.
    static let freshness: TimeInterval = 3 * 3_600

    private var loop: Task<Void, Never>?
    private weak var state: VRMMetalState?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Capturing

    /// Follows the scene that is on screen; restarting swaps the scene.
    func start(with state: VRMMetalState) {
        self.state = state
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                self?.captureNow(reason: "idle")
                try? await Task.sleep(for: Self.interval)
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Best effort: the frame may still be drawn before the scene pauses.
                self?.captureNow(reason: "resign")
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One capture of the settled scene, written as `latest.jpg`.
    func captureNow(reason: String) {
        guard let state, UIApplication.shared.applicationState == .active,
              state.currentModel != nil, state.firstFrameApplied, !state.isPlayingAppear
        else { return }
        state.captureFrame { image in
            guard let image else { return }
            Task.detached(priority: .utility) {
                guard Self.saveLatest(image) else { return }
                nlLog("[SceneCapture] latest capture written (\(reason))", level: .info)
            }
        }
    }

    // MARK: - Files

    static func directoryURL() -> URL? {
        guard let base = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? ProtectedStorage.protect(dir)
        }
        return dir
    }

    static var latestURL: URL? { directoryURL()?.appendingPathComponent(latestName) }

    nonisolated static func saveLatest(_ image: UIImage) -> Bool {
        guard let url = latestURL else { return false }
        let scaled = PhotoMemoryService.downscale(image, maxPixels: maxPixels)
        guard let data = scaled.jpegData(compressionQuality: 0.82),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return false }
        try? ProtectedStorage.protect(url)
        return true
    }

    /// The latest capture, when it is recent enough to be this session's.
    static func latestCapture(now: Date = Date()) -> URL? {
        guard let url = latestURL else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return isFresh(modifiedAt: modified, now: now, maxAge: freshness) ? url : nil
    }

    nonisolated static func isFresh(modifiedAt: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let modifiedAt else { return false }
        let age = now.timeIntervalSince(modifiedAt)
        return age >= 0 && age <= maxAge
    }

    /// Copies the latest capture into the journal's keeping; returns its
    /// file name, or nil when there is no fresh capture.
    static func keepForJournal(entryID: Int64, now: Date = Date()) -> String? {
        guard let source = latestCapture(now: now), let dir = directoryURL() else { return nil }
        let name = "journal-\(entryID).jpg"
        let target = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return nil }
        try? ProtectedStorage.protect(target)
        return name
    }

    static func journalURL(named name: String?) -> URL? {
        guard let name, !name.isEmpty, let dir = directoryURL() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func removeJournalFile(named name: String?) {
        guard let url = journalURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Notifications

    /// A notification attachment for a capture. The system MOVES the file it
    /// is given into its own store, so the attachment is built from a copy
    /// and the journal keeps its picture.
    static func attachment(copying source: URL, clipToFace: Bool = true) -> UNNotificationAttachment? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-\(UUID().uuidString).jpg")
        guard (try? FileManager.default.copyItem(at: source, to: temp)) != nil else { return nil }
        var options: [String: Any] = [:]
        if clipToFace {
            // Thumbnail on the upper middle of the frame, where she stands.
            options[UNNotificationAttachmentOptionsThumbnailClippingRectKey] =
                CGRect(x: 0.15, y: 0.0, width: 0.7, height: 0.7).dictionaryRepresentation
        }
        return try? UNNotificationAttachment(identifier: "companion-scene", url: temp, options: options)
    }
}
