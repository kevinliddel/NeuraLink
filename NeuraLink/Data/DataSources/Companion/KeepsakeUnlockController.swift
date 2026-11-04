//
//  KeepsakeUnlockController.swift
//  NeuraLink
//
//  Drives the "Keepsake collected" capsule (docs/LIVING_COMPANION.md):
//  the tracker hands over each newly recorded keepsake, the capsule shows
//  one at a time for a few seconds, and further unlocks wait their turn.
//  Same shape as PhotoshootShareController.
//
//  Created by Dedicatus on 14/10/2026.
//

import Foundation
import Observation

@Observable
final class KeepsakeUnlockController {
    static let shared = KeepsakeUnlockController()

    /// How long one capsule stays up before the next (or nothing) replaces it.
    static let lifetime: Duration = .seconds(5)

    private(set) var current: CompanionMilestone?
    private var queue: [CompanionMilestone] = []
    private var hideTask: Task<Void, Never>?

    private init() {}

    /// Shows the keepsake now, or after the ones already waiting.
    func present(_ keepsake: CompanionMilestone) {
        guard current == nil else {
            queue.append(keepsake)
            return
        }
        show(keepsake)
    }

    /// Hides the current capsule; the next queued keepsake takes its place.
    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        current = nil
        guard !queue.isEmpty else { return }
        show(queue.removeFirst())
    }

    /// Drops everything (tests, character switch).
    func reset() {
        hideTask?.cancel()
        hideTask = nil
        queue.removeAll()
        current = nil
    }

    private func show(_ keepsake: CompanionMilestone) {
        current = keepsake
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}
