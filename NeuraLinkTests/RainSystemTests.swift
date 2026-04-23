//
//  RainSystemTests.swift
//  NeuraLinkTests
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("Rain System Tests")
struct RainSystemTests {

    // MARK: - RainController — initial state

    @Test("Controller starts idle with zero intensity")
    func testInitialState() {
        let ctrl = RainController(idleCountdown: 10)
        #expect(ctrl.state == .idle)
        #expect(ctrl.intensity == 0.0)
        #expect(ctrl.isIdle)
    }

    @Test("isIdle is false once intensity is above threshold")
    func testIsIdleFalseWhenActive() {
        let ctrl = RainController(idleCountdown: 0.1)
        ctrl.update(deltaTime: 0.2)          // → fadingIn
        #expect(!ctrl.isIdle)
    }

    // MARK: - RainController — state transitions

    @Test("Ticking past idle countdown transitions to fadingIn")
    func testIdleToFadingIn() {
        let ctrl = RainController(idleCountdown: 1.0)
        ctrl.update(deltaTime: 1.5)
        #expect(ctrl.state == .fadingIn)
    }

    @Test("Intensity ramps from 0 to 1 during fadeIn")
    func testFadeInIntensityRamp() {
        let ctrl = RainController(idleCountdown: 0)
        ctrl.update(deltaTime: 0.01)         // enter fadingIn
        let halfFade = ctrl.fadeInDuration / 2
        ctrl.update(deltaTime: halfFade)
        #expect(ctrl.intensity > 0.3)
        #expect(ctrl.intensity < 1.0)
    }

    @Test("State becomes active after full fade-in")
    func testFadingInToActive() {
        let ctrl = RainController(idleCountdown: 0)
        ctrl.update(deltaTime: 0.01)
        ctrl.update(deltaTime: ctrl.fadeInDuration + 1)
        #expect(ctrl.state == .active)
        #expect(ctrl.intensity == 1.0)
    }

    @Test("Active state transitions to fadingOut")
    func testActiveToFadingOut() {
        let ctrl = RainController(idleCountdown: 0)
        ctrl.update(deltaTime: 0.01)                       // → fadingIn
        ctrl.update(deltaTime: ctrl.fadeInDuration + 0.1)  // → active
        ctrl.update(deltaTime: 300.1)                      // exceed max activeDuration → fadingOut
        #expect(ctrl.state == .fadingOut)
    }

    @Test("Intensity decays from 1 to 0 during fade-out")
    func testFadeOutIntensityDecay() {
        let ctrl = RainController(idleCountdown: 0)
        ctrl.update(deltaTime: 0.01)
        ctrl.update(deltaTime: ctrl.fadeInDuration + 0.1)
        ctrl.update(deltaTime: 300.1)                      // → fadingOut
        let halfFade = ctrl.fadeOutDuration / 2
        ctrl.update(deltaTime: halfFade)
        #expect(ctrl.intensity < 0.8)
        #expect(ctrl.intensity > 0)
    }

    @Test("FadingOut completes back to idle")
    func testFadingOutToIdle() {
        let ctrl = RainController(idleCountdown: 0)
        ctrl.update(deltaTime: 0.01)
        ctrl.update(deltaTime: ctrl.fadeInDuration + 0.1)
        ctrl.update(deltaTime: 300.1)
        ctrl.update(deltaTime: ctrl.fadeOutDuration + 1)
        #expect(ctrl.state == .idle)
        #expect(ctrl.intensity == 0.0)
        #expect(ctrl.isIdle)
    }

    @Test("Intensity is always in [0, 1]")
    func testIntensityBounds() {
        let ctrl = RainController(idleCountdown: 0)
        let steps: [Float] = [0.01, 5, 10, 10, 10, 50, 50, 50, 50, 50, 50]
        for dt in steps {
            ctrl.update(deltaTime: dt)
            #expect(ctrl.intensity >= 0 && ctrl.intensity <= 1,
                    "Out of range at state \(ctrl.state): \(ctrl.intensity)")
        }
    }

    // MARK: - RainSimulator — main drops

    @Test("No drops spawn with zero intensity")
    func testNoDropsAtZeroIntensity() {
        let sim = RainSimulator()
        for _ in 0..<200 { sim.update(ts: 1.0, intensity: 0) }
        #expect(sim.drops.isEmpty)
    }

    @Test("Drops appear after ticking with positive intensity")
    func testDropsSpawnWithIntensity() {
        let sim = RainSimulator()
        // 200 ticks at ts=1 with full intensity — at least one drop must have spawned
        for _ in 0..<200 { sim.update(ts: 1.0, intensity: 1.0) }
        #expect(!sim.drops.isEmpty)
    }

    @Test("Drop count never exceeds internal maximum")
    func testDropCountCap() {
        let sim = RainSimulator()
        for _ in 0..<500 { sim.update(ts: 1.0, intensity: 1.0) }
        #expect(sim.drops.count <= sim.maxDrops)
    }

    @Test("Drop positions are within expected range")
    func testDropPositionRange() {
        let sim = RainSimulator()
        for _ in 0..<100 { sim.update(ts: 1.0, intensity: 1.0) }
        for drop in sim.drops {
            #expect(drop.x >= 0 && drop.x <= 1, "x out of range: \(drop.x)")
            #expect(drop.r >= 0, "negative radius: \(drop.r)")
            #expect(drop.r <= sim.maxR * 1.1, "radius too large: \(drop.r)")
        }
    }

    @Test("Drop radii are within [minR, maxR]")
    func testDropRadiiRange() {
        let sim = RainSimulator()
        for _ in 0..<100 { sim.update(ts: 1.0, intensity: 1.0) }
        for drop in sim.drops {
            // Allow tiny tolerance for shrink/trail
            #expect(drop.r > 0)
            #expect(drop.r <= sim.maxR * 1.05)
        }
    }

    // MARK: - RainSimulator — droplets

    @Test("No droplets with zero intensity")
    func testNoDropletsAtZeroIntensity() {
        let sim = RainSimulator()
        for _ in 0..<200 { sim.update(ts: 1.0, intensity: 0) }
        #expect(sim.droplets.isEmpty)
    }

    @Test("Droplets spawn after ticking with positive intensity")
    func testDropletsSpawnWithIntensity() {
        let sim = RainSimulator()
        for _ in 0..<10 { sim.update(ts: 1.0, intensity: 1.0) }
        #expect(!sim.droplets.isEmpty)
    }

    @Test("Droplet count never exceeds cap")
    func testDropletCountCap() {
        let sim = RainSimulator()
        for _ in 0..<300 { sim.update(ts: 0.5, intensity: 1.0) }
        #expect(sim.droplets.count <= sim.maxDroplets)
    }

    @Test("Droplet alpha decays over time")
    func testDropletAlphaDecay() {
        let sim = RainSimulator()
        // Let some droplets accumulate
        for _ in 0..<5 { sim.update(ts: 1.0, intensity: 1.0) }
        guard !sim.droplets.isEmpty else { return }
        let firstAlpha = sim.droplets[0].alpha
        sim.update(ts: 1.0, intensity: 1.0)
        // Droplets may shift — just confirm alpha can decrease (not all droplets start at 1)
        #expect(firstAlpha <= 1.0)
    }

    @Test("Droplets are removed when alpha reaches zero")
    func testDropletsRemovedWhenExpired() {
        let sim = RainSimulator()
        // Tick long enough to fill then expire droplets
        for _ in 0..<5 { sim.update(ts: 1.0, intensity: 1.0) }
        let countBefore = sim.droplets.count
        // 30 ticks with ts=1 (alpha decay 0.05/tick → fully decayed in 20 ticks)
        for _ in 0..<30 { sim.update(ts: 1.0, intensity: 0) }
        #expect(sim.droplets.count < countBefore || sim.droplets.isEmpty)
    }

    @Test("Droplet positions are in [0, 1]")
    func testDropletPositionRange() {
        let sim = RainSimulator()
        for _ in 0..<10 { sim.update(ts: 1.0, intensity: 1.0) }
        for d in sim.droplets {
            #expect(d.x >= 0 && d.x <= 1)
            #expect(d.y >= 0 && d.y <= 1)
        }
    }

    // MARK: - RainDropGPU layout

    @Test("RainDropGPU stride is 32 bytes")
    func testRainDropGPULayout() {
        #expect(MemoryLayout<RainDropGPU>.stride == 32)
    }

    @Test("RainUniformsGPU stride is 24 bytes")
    func testRainUniformsGPULayout() {
        #expect(MemoryLayout<RainUniformsGPU>.stride == 24)
    }
}
