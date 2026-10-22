//
//  OpenVoicePresetTests.swift
//  NeuraLinkTests
//
//  The English local voices: every preset's embedding is bundled at the
//  size the converter expects, and a character with no saved voice gets one
//  that matches its gender.
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("OpenVoice presets")
struct OpenVoicePresetTests {

    @Test("Every preset ships a 256-float speaker embedding", arguments: OpenVoiceVoicePreset.allCases)
    func bundled(preset: OpenVoiceVoicePreset) throws {
        let url = try #require(OpenVoiceModelAccess.targetSE(named: preset.identifier), "\(preset.identifier).f32 missing")
        let data = try Data(contentsOf: url)
        #expect(data.count == 256 * MemoryLayout<Float>.size)
    }

    @Test("Two female and two male voices")
    func catalogue() {
        let byGender = Dictionary(grouping: OpenVoiceVoicePreset.allCases, by: \.gender)
        #expect(byGender[.female] == [.riko, .akira])
        #expect(byGender[.male] == [.touma, .ayanokoji])
    }

    @Test("A character with no saved voice gets one of its gender")
    func genderDefault() {
        #expect(OpenVoiceVoicePreset.builtInDefault(gender: .male).gender == .male)
        #expect(OpenVoiceVoicePreset.builtInDefault(gender: .female).gender == .female)
        for entry in VRMModelRegistry.shared.all where !entry.isImported {
            #expect(OpenVoiceVoicePreset.builtInDefault(for: entry.name).gender == entry.gender, "\(entry.name)")
        }
    }
}
