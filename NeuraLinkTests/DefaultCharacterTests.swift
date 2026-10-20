//
//  DefaultCharacterTests.swift
//  NeuraLinkTests
//
//  Oz is the factory character: the registry falls back to him, every
//  engine has a built-in prompt and voice for him, and the parts library
//  lists the donors that arrived with him (docs/CHARACTER_CUSTOMIZATION.md).
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
import UIKit
@testable import NeuraLink

@Suite("Default character")
struct DefaultCharacterTests {

    @Test("The registry's factory default is Oz whenever he is bundled")
    @MainActor
    func registryDefaultsToOz() {
        VRMModelRegistry.shared.refresh()
        // Unit-only builds may not package the models; the fallback chain is then untestable.
        guard VRMModelRegistry.shared.entry(named: "Oz") != nil else { return }
        #expect(VRMModelRegistry.shared.defaultModel?.name == "Oz")
        #expect(VRMModelRegistry.shared.defaultModel?.isImported == false)
        #expect(VRMModelRegistry.shared.entry(named: "Oz")?.gender == .male)
        #expect(VRMModelRegistry.shared.entry(named: "Ekaterina")?.gender == .female)
    }

    @Test("Both gender signs ship as symbols in the asset catalogue", arguments: CharacterGender.allCases)
    @MainActor
    func genderSymbolsShip(gender: CharacterGender) {
        // The pickers show only the sign, so a missing asset would be an empty segment.
        #expect(UIImage(named: gender.symbolAsset) != nil, "\(gender.symbolAsset) symbol")
        #expect(!gender.title.isEmpty)
    }

    @Test("Oz has a built-in persona, a male cloud voice and a reserved slug")
    @MainActor
    func ozPersona() {
        let persona = CharacterPersona.oz
        #expect(persona.name == "Oz")
        #expect(persona.voice == "ballad")
        #expect(persona.instructions.contains("butler"))
        #expect(persona.instructions.hasPrefix(CharacterPersona.emotionInstructions))
        #expect(VRMImportService.reservedSlugs.contains("oz"))
    }

    @Test("Every local engine has a prompt and a voice for Oz")
    @MainActor
    func ozLocalDefaults() {
        let configs: [LocalModelDownloadManager.ModelConfiguration?] = [nil, .llama1b, .llmJp3]
        for config in configs {
            let prompt = LocalLLMPromptStore.defaultPrompt(for: "Oz", config: config)
            #expect(prompt.contains("Oz") || prompt.contains("オズ"), "\(String(describing: config))")
        }
        #expect(VoiceVoxSpeaker.speakerID(for: "Oz") == VoiceVoxSpeaker.ritsu.id)
        #expect(OpenVoiceVoicePreset.builtInDefault(for: "Oz") == .akira)
    }

    @Test(
        "The donors added in October 2026 are in the parts manifest, typed and pinned",
        arguments: [
            "casual_boy", "casual_dark", "chill_boy", "dark_swimsuit", "duke",
            "ingrid", "jelsa", "john", "princess", "swimsuit", "wedding"
        ])
    @MainActor
    func donorsAreInTheManifest(model: String) {
        let items = PartsLibrary.shared.items.filter { $0.modelStem == model }
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.kind != nil })
        #expect(items.contains { $0.kind == .outfit })
        for item in items {
            #expect(RemoteAssetRegistry.libraryPart(item.stem).integrity != nil, "\(item.stem)")
        }
    }
}
