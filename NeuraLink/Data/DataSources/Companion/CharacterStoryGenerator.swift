//
//  CharacterStoryGenerator.swift
//  NeuraLink
//
//  Writes an imported character's story sheet from its persona prompt —
//  Inner life (docs/Companion/LIVING_COMPANION.md). One OpenAI text call
//  in labelled lines (StoryRecall.sheetInstruction / parseSheet); the
//  result is stored and stays editable in the character's settings. Runs
//  once after an import when a key is set, and on demand from the editor.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation

enum CharacterStoryGenerator {

    static var isAvailable: Bool {
        OpenAISettings.shared.isEnabled && OpenAISettings.shared.hasValidKey
    }

    /// A fresh sheet for `character`, or nil without a key or on failure.
    static func generate(character: String) async -> CharacterStorySheet? {
        guard isAvailable else { return nil }
        let persona = CharacterPersona.forCharacter(named: character)
        let description = CharacterPersona.strippingEmotionInstructions(persona.instructions)
        guard let raw = await OpenAIChatClient.complete(
            system: StoryRecall.sheetInstruction(name: persona.name), user: description,
            maxTokens: 1_100, temperature: 0.9, purpose: "characterStory")
        else { return nil }
        let sheet = StoryRecall.parseSheet(raw, character: character)
        // Fresh story ids, so what an earlier sheet shared is not credited to these.
        return sheet.isEmpty ? nil : CharacterStoryProvider.withFreshIDs(sheet, character: character)
    }

    /// After an import: writes and stores the sheet when there is none yet.
    static func seedIfNeeded(character: String) {
        guard isAvailable, CharacterStoryProvider.shared.sheet(for: character).isEmpty else { return }
        Task {
            // The character may have been deleted, or its sheet written by
            // hand, while the model was writing.
            guard let sheet = await generate(character: character),
                  ImportedCharacterStore.shared.isImported(slug: character.lowercased()),
                  CharacterStoryProvider.shared.sheet(for: character).isEmpty
            else { return }
            CharacterStoryProvider.shared.save(sheet, for: character)
            nlLog("[CharacterStory] \(character): story sheet written (\(sheet.fragments.count) stories)", level: .info)
        }
    }
}
