//
//  LLMGPUSentinel.swift
//  NeuraLink
//
//  Remembers whether running the local model on the GPU (Metal) is safe on a
//  4 GB device. SynapLink offloads its 1B model to Metal on the iPhone 11 and
//  streams several times faster than a 2-thread CPU decode, so NeuraLink now
//  does too — but this app also holds the avatar, the 3D scene and the TTS
//  model, and a load that pushes past the memory limit is killed by the
//  system (jetsam), which no code can catch. So a GPU load is marked pending
//  before it starts and confirmed after the first forward pass completes; a
//  launch that finds a load still pending knows the last one died. Xcode
//  stopping or re-running the app mid-load looks the same, so it takes TWO
//  unconfirmed loads in a row before the build stays on the CPU. A new build,
//  a fresh model download, or `-nl.llm.resetGPU YES` (DEBUG) tries again.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

nonisolated enum LLMGPUSentinel {
    private static let pendingKey = "nl.llm.gpu.pendingBuild"
    private static let unsafeKey = "nl.llm.gpu.unsafeBuild"
    private static let strikesKey = "nl.llm.gpu.strikes"
    /// Unconfirmed GPU loads in a row before this build stays on the CPU.
    static let strikesToDisable = 2
    private static let lock = NSLock()
    private nonisolated(unsafe) static var checkedThisLaunch = false
    private nonisolated(unsafe) static var confirmedThisLaunch = false

    static var currentBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    /// Whether this build may load the model onto the GPU. On the first call
    /// of a launch, a GPU load still pending from the previous run marks the
    /// build unsafe.
    static func gpuAllowed(defaults: UserDefaults = .standard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !checkedThisLaunch {
            checkedThisLaunch = true
            #if DEBUG
            if defaults.bool(forKey: "nl.llm.resetGPU") { resetLocked(defaults) }
            #endif
            if let pending = defaults.string(forKey: pendingKey) {
                defaults.removeObject(forKey: pendingKey)
                let strikes = defaults.integer(forKey: strikesKey) + 1
                defaults.set(strikes, forKey: strikesKey)
                if strikes >= strikesToDisable {
                    defaults.set(pending, forKey: unsafeKey)
                    nlLog("[LLMGPU] \(strikes) GPU loads in a row never finished (build \(pending)) — staying on the CPU for this build.",
                          level: .warning)
                } else {
                    nlLog("[LLMGPU] The last GPU load never finished (strike \(strikes)/\(strikesToDisable)) — trying the GPU again.",
                          level: .warning)
                }
            }
        }
        let allowed = defaults.string(forKey: unsafeKey) != currentBuild
        if !allowed { nlLog("[LLMGPU] GPU disabled for build \(currentBuild) after repeated failed loads.", level: .info) }
        return allowed
    }

    /// Marks a GPU load as in flight. Call just before creating the context.
    static func beginGPULoad(defaults: UserDefaults = .standard) {
        lock.withLock { confirmedThisLaunch = false }
        defaults.set(currentBuild, forKey: pendingKey)
    }

    /// The model ran a forward pass on the GPU and the app is still alive.
    static func confirmGPUWorks(defaults: UserDefaults = .standard) {
        let first = lock.withLock { () -> Bool in
            defer { confirmedThisLaunch = true }
            return !confirmedThisLaunch
        }
        guard first, defaults.string(forKey: pendingKey) != nil else { return }
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: strikesKey)
        nlLog("[LLMGPU] GPU load confirmed (build \(currentBuild)).", level: .info)
    }

    /// Forget past failures — a fresh model download gets a clean slate.
    static func reset(defaults: UserDefaults = .standard) {
        lock.withLock { resetLocked(defaults) }
    }

    private static func resetLocked(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: unsafeKey)
        defaults.removeObject(forKey: strikesKey)
    }

    /// Test seam: forget this launch's bookkeeping.
    static func resetForTesting() {
        lock.withLock {
            checkedThisLaunch = false
            confirmedThisLaunch = false
        }
    }
}
