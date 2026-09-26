//
//  CompanionSnapshotWriter.swift
//  NeuraLink
//
//  Builds the widget snapshot from app state and writes it to the App
//  Group (docs/PRESENCE_BEYOND_APP_PLAN.md §P3). Called after reflections,
//  relationship refreshes and character switches; debounced so a burst of
//  messages produces one write. Honours the "Show companion widgets"
//  privacy toggle (off → the snapshot is deleted).
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import WidgetKit

final class CompanionSnapshotWriter: @unchecked Sendable {
    static let shared = CompanionSnapshotWriter()

    /// Minimum gap between writes; more frequent requests coalesce.
    static let debounce: Duration = .seconds(5)

    private var pending: Task<Void, Never>?

    private init() {}

    /// Coalesced refresh. Safe to call from anywhere on the main actor.
    @MainActor
    func scheduleRefresh() {
        guard PresenceSettings.shared.showWidgets else {
            CompanionSnapshotStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    @MainActor
    func writeNow() {
        let character = RealtimeChatState.shared.selectedCharacterName
        guard !character.isEmpty else { return }
        let store = MemoryStore.shared
        let affinity = CompanionAffinity.compute(store: store)
        let opener = store.latestUnusedOpener(character: character)?.opener ?? ""
        let memoryLine = Self.memoryOfTheDay(from: store.fetchUnits(factTypes: [.observation]))
        var thumbnailFile: String?
        if let png = CompanionNotificationScheduler.characterThumbnailData(for: character) {
            thumbnailFile = CompanionSnapshotStore.saveThumbnail(png, for: character)
        }
        let snapshot = CompanionSnapshot(
            character: character.lowercased(),
            displayName: VRMModelRegistry.shared.entry(named: character)?.displayName ?? character.capitalized,
            relationshipLabel: affinity.label,
            relationshipScore: affinity.score,
            opener: opener,
            memoryLine: memoryLine,
            lastChatAt: InteractionClock.shared.lastUserSpeechAt ?? InteractionClock.shared.lastSeenAt,
            thumbnailFile: thumbnailFile,
            updatedAt: Date())
        if CompanionSnapshotStore.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
            nlLog("[Widgets] snapshot written for \(character)", level: .info)
        }
    }

    /// One observation, chosen by the day so the widget rotates without the
    /// app having to remember anything. Empty when there are none.
    nonisolated static func memoryOfTheDay(from observations: [MemoryUnit], date: Date = Date()) -> String {
        let candidates = observations.map(\.text).filter { $0.count <= 140 }
        guard !candidates.isEmpty else { return "" }
        let day = Int(date.timeIntervalSince1970 / 86_400)
        return candidates[day % candidates.count]
    }
}
