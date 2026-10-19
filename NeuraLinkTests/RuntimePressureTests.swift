//
//  RuntimePressureTests.swift
//  NeuraLinkTests
//
//  Thermal / Low Power tiering (docs/OPT.md item 7).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Runtime pressure")
struct RuntimePressureTests {

    @Test("Serious heat or Low Power Mode reduces; critical heat is the floor")
    func tiers() {
        #expect(RuntimePressurePolicy.tier(thermal: 0, lowPower: false) == .normal)
        #expect(RuntimePressurePolicy.tier(thermal: 1, lowPower: false) == .normal)
        #expect(RuntimePressurePolicy.tier(thermal: 2, lowPower: false) == .reduced)
        #expect(RuntimePressurePolicy.tier(thermal: 0, lowPower: true) == .reduced)
        #expect(RuntimePressurePolicy.tier(thermal: 3, lowPower: false) == .minimal)
        #expect(RuntimePressurePolicy.tier(thermal: 3, lowPower: true) == .minimal)
        #expect(RuntimePressureTier.normal < .reduced && .reduced < .minimal)
    }

    @Test("Each tier caps the frame rate, the rain and the LLM threads")
    func caps() {
        #expect(RuntimePressurePolicy.renderFPSCap(.normal) == 60)
        #expect(RuntimePressurePolicy.renderFPSCap(.reduced) == 30)
        #expect(RuntimePressurePolicy.renderFPSCap(.minimal) == 24)
        #expect(RuntimePressurePolicy.rainScale(.normal) == 1)
        #expect(RuntimePressurePolicy.rainScale(.reduced) == 0.4)
        #expect(RuntimePressurePolicy.rainScale(.minimal) == 0)
        #expect(RuntimePressurePolicy.threadCap(.normal) == nil)
        #expect(RuntimePressurePolicy.threadCap(.reduced) == 2)
        #expect(RuntimePressurePolicy.threadCap(.minimal) == 2)
        #expect(RuntimePressureMonitor.currentTier(thermal: .serious, lowPower: false) == .reduced)
    }
}
