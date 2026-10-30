//
//  RuntimePressure.swift
//  NeuraLink
//
//  Thermal / Low Power Mode tiering: one policy that
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

    /// Whether the avatar renders its received shadows (an extra 2048² depth
    /// pass and nine compares per pixel): dropped only at the minimal tier.
    static func avatarSelfShadows(_ tier: RuntimePressureTier) -> Bool {
        tier != .minimal
    }

    /// How far the sun or moon moves, in degrees, before the sky's
    /// atmosphere is worked out again: twice as far, so half as often, on a
    /// hot or power-saving phone.
    static func skyRefreshDegrees(_ tier: RuntimePressureTier) -> Float {
        tier == .normal ? 0.1 : 0.2
    }

    /// Cloud layers the sky draws: the thin high veil goes under pressure,
    /// the heaped low clouds stay.
    static func skyCloudLayers(_ tier: RuntimePressureTier) -> Int {
        tier == .normal ? 2 : 1
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
