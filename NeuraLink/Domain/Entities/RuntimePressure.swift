//
//  RuntimePressure.swift
//  NeuraLink
//
//  Thermal / Low Power Mode tiering (docs/OPT.md item 7): one policy that
//  says how hard the app may push when the phone is hot or saving power.
//  Pure and unit-tested; `RuntimePressureMonitor` feeds it from
//  ProcessInfo, and the renderer, the rain and the LLM profile read it.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation

enum RuntimePressureTier: Int, Comparable, Sendable {
    /// Cool and plugged in or on a full battery: no limits.
    case normal = 0
    /// Serious thermal state, or Low Power Mode: half the frame rate, most
    /// of the rain, no more than two LLM threads.
    case reduced
    /// Critical thermal state: the floor — enough to stay responsive.
    case minimal

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum RuntimePressurePolicy {

    /// `thermal` is `ProcessInfo.ThermalState.rawValue`: 0 nominal, 1 fair,
    /// 2 serious, 3 critical.
    static func tier(thermal: Int, lowPower: Bool) -> RuntimePressureTier {
        if thermal >= 3 { return .minimal }
        if thermal >= 2 || lowPower { return .reduced }
        return .normal
    }

    /// Ceiling for the render loop's preferred frame rate.
    static func renderFPSCap(_ tier: RuntimePressureTier) -> Int {
        switch tier {
        case .normal: return 60
        case .reduced: return 30
        case .minimal: return 24
        }
    }

    /// Multiplier on the rain's intensity (particles spawn in proportion).
    static func rainScale(_ tier: RuntimePressureTier) -> Float {
        switch tier {
        case .normal: return 1
        case .reduced: return 0.4
        case .minimal: return 0
        }
    }

    /// Most generation threads the local LLM may use; nil leaves the tier's
    /// sweep-tuned count alone.
    static func threadCap(_ tier: RuntimePressureTier) -> Int32? {
        tier == .normal ? nil : 2
    }
}
