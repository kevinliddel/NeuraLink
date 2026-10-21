//
//  FacePresenceDetector.swift
//  NeuraLink
//
//  Is someone in front of the phone, and where? On-device Vision face
//  detection on the frames CameraManager already captures, a few times a
//  second, nothing leaves the device (docs/LIVING_COMPANION.md, Desk
//  presence). Feeds the desk-presence policy and the look-at.
//
//  Created by Dedicatus on 19/10/2026.
//

import AVFoundation
import CoreVideo
import Foundation
import Observation
import Vision

@Observable
final class FacePresenceDetector {
    static let shared = FacePresenceDetector()

    static let interval: Duration = .milliseconds(400)
    static let idleInterval: Duration = .seconds(1)
    /// Posted on every detection pass; the scene reads `facePresent` / `faceCenter`.
    static let didUpdate = Notification.Name("NeuraLink.FacePresence.didUpdate")

    private(set) var facePresent = false
    /// Normalised in the upright frame, origin top-left.
    private(set) var faceCenter: CGPoint?
    private(set) var faceWidth: CGFloat?
    private(set) var lastSeenAt: Date?
    private(set) var isRunning = false

    /// Consecutive empty passes before "nobody": one missed frame must not
    /// snap her gaze away.
    static let missesBeforeAbsent = 2
    private var missStreak = 0
    private var loop: Task<Void, Never>?

    private init() {}

    func start() {
        guard loop == nil else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if CameraManager.shared.isActive, let frame = CameraManager.shared.latestFrame() {
                    let orientation = Self.orientation(for: CameraManager.shared.cameraPosition)
                    let face = await Self.detect(in: frame, orientation: orientation)
                    self.apply(face)
                    try? await Task.sleep(for: Self.interval)
                } else {
                    if self.facePresent { self.apply(nil) }
                    try? await Task.sleep(for: Self.idleInterval)
                }
            }
        }
        nlLog("[FacePresence] started", level: .info)
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
        apply(nil)
        nlLog("[FacePresence] stopped", level: .info)
    }

    private func apply(_ face: (center: CGPoint, width: CGFloat)?) {
        let was = facePresent
        if let face {
            missStreak = 0
            facePresent = true
            faceCenter = face.center
            faceWidth = face.width
            lastSeenAt = Date()
        } else {
            missStreak += 1
            guard missStreak >= Self.missesBeforeAbsent || !facePresent else { return }
            facePresent = false
            faceCenter = nil
            faceWidth = nil
        }
        if was != facePresent { nlLog("[FacePresence] \(facePresent ? "face" : "nobody")", level: .info) }
        NotificationCenter.default.post(name: Self.didUpdate, object: nil)
    }

    /// How the landscape buffer stands up: the front camera's frames are
    /// mirrored and rotated the other way from the back camera's. Handing
    /// Vision the back camera's hint for the front camera gives it an
    /// upside-down face: flickering detection and a flipped centre.
    nonisolated static func orientation(for position: AVCaptureDevice.Position) -> CGImagePropertyOrientation {
        position == .front ? .leftMirrored : .right
    }

    /// The largest face in the frame, or nil.
    nonisolated static func detect(
        in buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation
    ) async -> (center: CGPoint, width: CGFloat)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
                try? handler.perform([request])
                let largest = (request.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }
                guard let box = largest?.boundingBox else {
                    continuation.resume(returning: nil)
                    return
                }
                // Vision's origin is bottom-left.
                continuation.resume(returning: (CGPoint(x: box.midX, y: 1 - box.midY), box.width))
            }
        }
    }
}
