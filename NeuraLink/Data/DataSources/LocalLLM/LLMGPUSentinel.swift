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
//  launch that finds a load still pending knows the last one died, and keeps
//  that build on the CPU. A new build tries the GPU again once.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

nonisolated enum LLMGPUSentinel {
    private static let pendingKey = "nl.llm.gpu.pendingBuild"
    private static let unsafeKey = "nl.llm.gpu.unsafeBuild"
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
            if let pending = defaults.string(forKey: pendingKey) {
                defaults.set(pending, forKey: unsafeKey)
                defaults.removeObject(forKey: pendingKey)
                nlLog("[LLMGPU] The last GPU load (build \(pending)) never finished — staying on the CPU for this build.",
                      level: .warning)
            }
        }
        return defaults.string(forKey: unsafeKey) != currentBuild
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
        nlLog("[LLMGPU] GPU load confirmed (build \(currentBuild)).", level: .info)
    }

    /// Test seam: forget this launch's bookkeeping.
    static func resetForTesting() {
        lock.withLock {
            checkedThisLaunch = false
            confirmedThisLaunch = false
        }
    }
}
