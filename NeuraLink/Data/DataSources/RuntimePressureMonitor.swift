//
//  RuntimePressureMonitor.swift
//  NeuraLink
//
//  Keeps the current `RuntimePressureTier` from ProcessInfo's thermal state
//  and Low Power Mode. Observable, so the render loop
//  re-evaluates its frame rate and rain budget the moment the tier moves.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation
import Observation

@Observable
final class RuntimePressureMonitor {
    static let shared = RuntimePressureMonitor()

    private(set) var tier: RuntimePressureTier = .normal

    private init() {
        refresh()
        let center = NotificationCenter.default
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The tier for the given readings (the monitor's own, by default).
    static func currentTier(
        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> RuntimePressureTier {
        RuntimePressurePolicy.tier(thermal: thermal.rawValue, lowPower: lowPower)
    }

    private func refresh() {
        let next = Self.currentTier()
        guard next != tier else { return }
        tier = next
        nlLog(
            "[Pressure] tier → \(next) (thermal \(ProcessInfo.processInfo.thermalState.rawValue), "
                + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)): "
                + "fps ≤ \(RuntimePressurePolicy.renderFPSCap(next)), rain ×\(RuntimePressurePolicy.rainScale(next))",
            level: .info)
    }
}
