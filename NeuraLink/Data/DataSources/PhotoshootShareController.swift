//
//  PhotoshootShareController.swift
//  NeuraLink
//
//  Holds the picture taken by `pose_for_photo` and drives the save/share
//  capsule (docs/MEMORY_OWNERSHIP_PLAN.md §M2).
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import Observation
import Photos
import UIKit

@Observable
final class PhotoshootShareController {
    static let shared = PhotoshootShareController()

    /// Delay after the pose starts before the frame is captured (lets the
    /// animation settle) and how long the capsule stays up.
    static let captureDelay: Duration = .seconds(2)
    static let capsuleLifetime: Duration = .seconds(12)

    var image: UIImage?
    var isCapsuleVisible = false
    var saveState: SaveState = .idle

    enum SaveState: Equatable { case idle, saving, saved, failed }

    private var hideTask: Task<Void, Never>?
    /// Hook for tests / previews; production captures the Metal scene.
    var capture: (@escaping @Sendable (UIImage?) -> Void) -> Void = { completion in
        NotificationCenter.default.post(name: .photoshootCaptureRequested, object: nil, userInfo: ["completion": CaptureBox(completion)])
    }

    private init() {}

    /// Called by the photoshoot skill once the pose is playing.
    func schedulePhoto() {
        saveState = .idle
        Task { [weak self] in
            try? await Task.sleep(for: Self.captureDelay)
            guard let self else { return }
            self.capture { image in
                Task { @MainActor in self.didCapture(image) }
            }
        }
    }

    func didCapture(_ image: UIImage?) {
        guard let image else { return }
        self.image = image
        // Wait for the UI to come back (the skill hides it for 5 s) so the
        // capsule does not sit on an empty screen.
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, let self else { return }
            self.isCapsuleVisible = true
            try? await Task.sleep(for: Self.capsuleLifetime)
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        hideTask?.cancel()
        isCapsuleVisible = false
    }

    func saveToPhotos() {
        guard let image, saveState != .saving else { return }
        saveState = .saving
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveState = .failed
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                saveState = .saved
            } catch {
                nlLog("[Photoshoot] save failed: \(error)", level: .warning)
                saveState = .failed
            }
        }
    }
}

/// Reference wrapper so a closure can travel in a notification's userInfo.
final class CaptureBox: @unchecked Sendable {
    let completion: @Sendable (UIImage?) -> Void
    init(_ completion: @escaping @Sendable (UIImage?) -> Void) { self.completion = completion }
}

extension Notification.Name {
    /// Posted by `PhotoshootShareController`; answered by the scene owner.
    static let photoshootCaptureRequested = Notification.Name("NLPhotoshootCaptureRequested")
}
