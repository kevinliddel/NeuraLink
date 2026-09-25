//
//  MemoryBankTests.swift
//  NeuraLinkTests
//
//  Per-character memory banks + disposition persistence
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C4).
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Memory banks", .serialized)
struct MemoryBankTests {

    @Test("Bank policy: user facts shared, character output private")
    func policy() {
        #expect(MemoryBanks.bank(for: .world, source: "retain", character: "sonya") == "")
        #expect(MemoryBanks.bank(for: .raw, source: "user", character: "sonya") == "")
        #expect(MemoryBanks.bank(for: .raw, source: "ai", character: "sonya") == "sonya")
        #expect(MemoryBanks.bank(for: .experience, source: "retain", character: "sonya") == "sonya")
        #expect(MemoryBanks.bank(for: .observation, source: "consolidation", character: "sonya") == "sonya")
    }

    @Test("Readable banks follow the sharing toggle")
    func readable() {
        let settings = MemorySettings.shared
        let original = settings.charactersShareMemories
        defer { settings.charactersShareMemories = original }
        settings.charactersShareMemories = true
        #expect(MemoryBanks.readable(for: "sonya") == nil)
        settings.charactersShareMemories = false
        #expect(MemoryBanks.readable(for: "Sonya") == ["", "sonya"])
    }

    @Test("Store filters units by bank and keeps the shared bank visible")
    func storeFilter() {
        let store = MemoryStore.shared
        let shared = store.insertUnit(text: "User keeps a Zyqxbank plant.", vector: [0.1], factType: .world, source: "t")
        let sonya = store.insertUnit(
            text: "Sonya teased the user about the Zyqxbank plant.", vector: [0.1], factType: .experience, source: "t",
            bank: "sonya")
        let eka = store.insertUnit(
            text: "Ekaterina admired the Zyqxbank plant.", vector: [0.1], factType: .experience, source: "t",
            bank: "ekaterina")
        defer { [shared, sonya, eka].forEach { store.deleteUnit(id: $0) } }

        let visible = store.fetchUnits(factTypes: [.world, .experience], banks: ["", "sonya"]).map(\.id)
        #expect(visible.contains(shared))
        #expect(visible.contains(sonya))
        #expect(!visible.contains(eka))
        #expect(store.fetchUnit(id: eka)?.bank == "ekaterina")
        #expect(store.fetchUnits(factTypes: [.experience]).map(\.id).contains(eka), "nil banks = everything")
    }

    @Test("Disposition persists per character and renders only non-neutral traits")
    func disposition() {
        let character = "testchar-zyqx"
        defer { MemoryDisposition.neutral.save(forCharacter: character) }
        #expect(MemoryDisposition.forCharacter(character) == .neutral)
        #expect(MemoryDisposition.neutral.promptDescription.isEmpty)
        MemoryDisposition(skepticism: 5, literalism: 1, empathy: 3).save(forCharacter: character)
        let loaded = MemoryDisposition.forCharacter(character)
        #expect(loaded.skepticism == 5 && loaded.literalism == 1 && loaded.empathy == 3)
        #expect(loaded.promptDescription.contains("highly skeptical"))
        #expect(loaded.promptDescription.contains("between the lines"))
        #expect(!loaded.promptDescription.contains("emotional"))
    }
}
