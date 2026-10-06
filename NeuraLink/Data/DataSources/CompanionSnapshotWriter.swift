//
//  CompanionSnapshotWriter.swift
//  NeuraLink
//
//  Builds the widget snapshot from app state and writes it to the App
//  Group (docs/PRESENCE_BEYOND_APP.md). Kept in sync with the live app:
//    • relationship meter — every logged message (CompanionStateStore),
//    • memory — reflections and memory-summary (mental model) updates,
//    • the character — a switch or a customization re-renders a portrait
//      of the model as it is dressed right now (not the stock thumbnail).
//  Writes are debounced so a burst of messages produces one write, and a
//  pending write is flushed when the app backgrounds — a plain debounce
//  task would be suspended with the app and never land. Honours the "Show
//  companion widgets" privacy toggle (off → the snapshot is deleted).
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import UIKit
import WidgetKit

final class CompanionSnapshotWriter: @unchecked Sendable {
    static let shared = CompanionSnapshotWriter()

    /// Minimum gap between writes; more frequent requests coalesce.
    static let debounce: Duration = .seconds(5)
    /// Memory-line length the widget can show without truncating badly.
    static let memoryLineLimit = 150

    private var pending: Task<Void, Never>?
    private var portraitTask: Task<Void, Never>?
    /// Live portrait file per character, once rendered this launch.
    private var portraitFiles: [String: String] = [:]
    private var portraitRenderer: VRMPartThumbnailRenderer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in CompanionSnapshotWriter.shared.flushPending() }
        }
    }

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
            self?.pending = nil
            self?.writeNow()
        }
    }

    /// Writes immediately if a debounced write is waiting.
    @MainActor
    func flushPending() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        writeNow()
    }

    /// Re-renders the character's portrait from the live model once it has
    /// settled into its idle (never the bind pose or the entrance), then
    /// writes the snapshot. Call after a character loads or its look changes.
    @MainActor
    func refreshPortrait(from state: VRMMetalState) {
        guard PresenceSettings.shared.showWidgets, let model = state.currentModel else { return }
        let character = RealtimeChatState.shared.selectedCharacterName
        guard !character.isEmpty else { return }
        portraitTask?.cancel()
        portraitTask = Task { [weak self] in
            // Up to ~20 s for the entrance to finish; then a beat so the
            // crossfade into the idle is done.
            for _ in 0..<40 where !(state.firstFrameApplied && !state.isPlayingAppear) {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, state.currentModel === model,
                  RealtimeChatState.shared.selectedCharacterName == character
            else { return }
            self.renderPortrait(of: model, layer: state.renderer?.appearanceLayer, character: character)
            self.pending?.cancel()
            self.pending = nil
            self.writeNow()
        }
    }

    @MainActor
    private func renderPortrait(of model: VRMModel, layer: AppearanceMaterialLayer?, character: String) {
        if portraitRenderer == nil { portraitRenderer = VRMPartThumbnailRenderer(size: 512) }
        guard let image = portraitRenderer?.renderPortrait(of: model, recolorsFrom: layer),
              let png = image.pngData(),
              let file = CompanionSnapshotStore.saveThumbnail(png, for: "\(character)_live")
        else {
            nlLog("[Widgets] live portrait render failed for \(character)", level: .warning)
            return
        }
        portraitFiles[character.lowercased()] = file
        nlLog("[Widgets] live portrait rendered for \(character)", level: .info)
    }

    @MainActor
    func writeNow() {
        guard PresenceSettings.shared.showWidgets else { return }
        let character = RealtimeChatState.shared.selectedCharacterName
        guard !character.isEmpty else { return }
        let store = MemoryStore.shared
        let affinity = CompanionAffinity.compute(store: store)
        let opener = store.latestUnusedOpener(character: character)?.opener ?? ""
        let memory = Self.memoryLine(
            models: store.fetchMentalModels(character: character),
            observations: store.fetchUnits(factTypes: [.observation]))

        var thumbnailFile = portraitFiles[character.lowercased()]
        if thumbnailFile == nil, let png = CompanionNotificationScheduler.characterThumbnailData(for: character) {
            thumbnailFile = CompanionSnapshotStore.saveThumbnail(png, for: character)
        }
        let snapshot = CompanionSnapshot(
            character: character.lowercased(),
            // Same resolver as prompts and notifications: a renamed import
            // shows its new name, not the file stem it was imported under.
            displayName: RealtimeChatState.displayName(for: character),
            relationshipLabel: affinity.label,
            relationshipScore: affinity.score,
            opener: opener,
            memoryLine: memory.line,
            memoryTitle: memory.title,
            factCount: store.fetchAllFacts().count,
            daysTogether: store.distinctUserMessageDays(),
            lastChatAt: InteractionClock.shared.lastUserSpeechAt ?? InteractionClock.shared.lastSeenAt,
            thumbnailFile: thumbnailFile,
            updatedAt: Date())
        if CompanionSnapshotStore.save(snapshot) {
            WidgetCenter.shared.reloadAllTimelines()
            nlLog("[Widgets] snapshot written for \(character)", level: .info)
        }
    }

    // MARK: - Memory line (pure, unit-tested)

    /// The opening of the memory summary — "Between you" first, then
    /// "About you" — falling back to the observation of the day.
    static func memoryLine(
        models: [MentalModel], observations: [MemoryUnit], date: Date = Date()
    ) -> (line: String, title: String?) {
        for (slug, title) in [(MemoryMentalModels.relationshipSlug, "Between you"),
                              (MemoryMentalModels.userProfileSlug, "About you")] {
            if let content = models.first(where: { $0.slug == slug })?.content,
               let line = leadingSentence(of: content) {
                return (line, title)
            }
        }
        let observation = memoryOfTheDay(from: observations, date: date)
        return (observation, observation.isEmpty ? nil : "Remembered")
    }

    /// First sentence of `text`, cut at a word boundary to fit the widget.
    nonisolated static func leadingSentence(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sentence = trimmed
        if let end = trimmed.firstIndex(where: { ".!?".contains($0) }) {
            sentence = String(trimmed[...end])
        }
        guard sentence.count > memoryLineLimit else { return sentence }
        let cut = sentence.prefix(memoryLineLimit)
        let words = cut.split(separator: " ").dropLast()
        return words.joined(separator: " ") + "…"
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
