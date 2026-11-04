//
//  AutonomyPresetTests.swift
//  NeuraLinkTests
//
//  The Autonomy screen's presets (docs/LIVING_COMPANION.md).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Autonomy presets")
struct AutonomyPresetTests {

    @Test("Presets are ordered by initiative and each matches only itself")
    func presets() {
        #expect(AutonomyPreset.quiet.flags.onCount < AutonomyPreset.balanced.flags.onCount)
        #expect(AutonomyPreset.balanced.flags.onCount < AutonomyPreset.lively.flags.onCount)
        #expect(AutonomyPreset.lively.flags.onCount == 10)
        for preset in AutonomyPreset.allCases {
            #expect(AutonomyPreset.matching(preset.flags) == preset)
            #expect(!preset.title.isEmpty && !preset.blurb.isEmpty && !preset.symbol.isEmpty)
        }
    }

    @Test("Every preset keeps auto-turn on; Balanced stays silent between sessions")
    func contents() {
        #expect(AutonomyPreset.allCases.allSatisfy { $0.flags.autoTurn })
        #expect(!AutonomyPreset.balanced.flags.engagement && !AutonomyPreset.balanced.flags.notifications)
        #expect(AutonomyPreset.balanced.flags.presence && AutonomyPreset.balanced.flags.widgets)
        #expect(!AutonomyPreset.quiet.flags.presence)
    }

    @Test("A custom mix matches no preset")
    func custom() {
        var flags = AutonomyPreset.balanced.flags
        flags.keepTalking = true
        #expect(AutonomyPreset.matching(flags) == nil)
    }
}
