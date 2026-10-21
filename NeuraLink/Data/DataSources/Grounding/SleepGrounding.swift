//
//  SleepGrounding.swift
//  NeuraLink
//
//  HealthKit read behind the sleep line (docs/LIVING_COMPANION.md):
//  last night's sleep-analysis samples, split into "asleep" (stages, from
//  a Watch or a sleep app) and "in bed" (what the iPhone alone records).
//  Read-only; nothing is ever written to Health.
//
//  Created by Dedicatus on 15/10/2026.
//

import Foundation
import HealthKit

final class SleepGrounding {
    static let shared = SleepGrounding()

    /// How far back "last night" reaches.
    static let lookbackHours = 24.0

    private let store = HKHealthStore()
    private let sleepType = HKCategoryType(.sleepAnalysis)

    private init() {}

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Asks to read sleep analysis. HealthKit never reveals whether a read
    /// was denied; a denial simply yields no samples.
    func requestAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
            nlLog("[Grounding] sleep access requested", level: .info)
            return true
        } catch {
            nlLog("[Grounding] sleep access request failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    /// Last night's summary, or nil when HealthKit holds nothing for it.
    func lastNight(now: Date = Date()) async -> SleepSummary? {
        guard Self.isAvailable else { return nil }
        let start = now.addingTimeInterval(-Self.lookbackHours * 3_600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate)
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        var asleep: [DateInterval] = []
        var inBed: [DateInterval] = []
        for sample in samples {
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
            let interval = DateInterval(start: sample.startDate, end: sample.endDate)
            switch value {
            case .inBed: inBed.append(interval)
            case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: asleep.append(interval)
            case .awake: continue
            @unknown default: continue
            }
        }
        return DailyGrounding.summary(asleep: asleep, inBed: inBed)
    }
}
