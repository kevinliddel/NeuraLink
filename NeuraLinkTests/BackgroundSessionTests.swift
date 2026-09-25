//
//  BackgroundSessionTests.swift
//  NeuraLinkTests
//
//  Keep-alive policy for background voice sessions (docs/PRESENCE_BEYOND_APP_PLAN.md §P1).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Background session policy")
struct BackgroundSessionTests {

    @Test("Only an opted-in, live, cool, non-low-power session is kept alive")
    func onBackground() {
        typealias Policy = BackgroundSessionPolicy
        #expect(Policy.onBackground(keepTalking: true, status: .ready, lowPower: false, thermal: .nominal) == .keepAlive)
        #expect(Policy.onBackground(keepTalking: true, status: .speaking, lowPower: false, thermal: .fair) == .keepAlive)
        #expect(Policy.onBackground(keepTalking: true, status: .reconnecting(attempt: 2), lowPower: false, thermal: .nominal) == .keepAlive)
        #expect(Policy.onBackground(keepTalking: false, status: .ready, lowPower: false, thermal: .nominal) == .endSession)
        #expect(Policy.onBackground(keepTalking: true, status: .disconnected, lowPower: false, thermal: .nominal) == .endSession)
        #expect(Policy.onBackground(keepTalking: true, status: .error("x"), lowPower: false, thermal: .nominal) == .endSession)
        #expect(Policy.onBackground(keepTalking: true, status: .ready, lowPower: true, thermal: .nominal) == .endSession)
        #expect(Policy.onBackground(keepTalking: true, status: .ready, lowPower: false, thermal: .serious) == .endSession)
    }

    @Test("Background session ends on idle timeout or any battery guard")
    func shouldEnd() {
        typealias Policy = BackgroundSessionPolicy
        #expect(!Policy.shouldEnd(idleSeconds: 100, idleLimit: 600, lowPower: false, thermal: .nominal, memoryWarning: false))
        #expect(Policy.shouldEnd(idleSeconds: 600, idleLimit: 600, lowPower: false, thermal: .nominal, memoryWarning: false))
        #expect(!Policy.shouldEnd(idleSeconds: nil, idleLimit: 600, lowPower: false, thermal: .nominal, memoryWarning: false))
        #expect(Policy.shouldEnd(idleSeconds: 0, idleLimit: 600, lowPower: true, thermal: .nominal, memoryWarning: false))
        #expect(Policy.shouldEnd(idleSeconds: 0, idleLimit: 600, lowPower: false, thermal: .critical, memoryWarning: false))
        #expect(Policy.shouldEnd(idleSeconds: 0, idleLimit: 600, lowPower: false, thermal: .nominal, memoryWarning: true))
    }
}
