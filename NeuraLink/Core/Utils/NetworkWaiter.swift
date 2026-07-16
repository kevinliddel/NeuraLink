//
//  NetworkWaiter.swift
//  NeuraLink
//
//  Awaitable "wait until the network is reachable" built on NWPathMonitor.
//  Used by the first-install environment download: on a fresh install the
//  first requests can race iOS's network-access grant (the path reports
//  "unsatisfied (Denied over Wi-Fi)" → NSURLError -1009), so instead of
//  burning retry attempts while offline, callers wait for the path to become
//  satisfied — bounded by a timeout so a truly offline device still falls
//  through to the normal failure path.
//
//  Created by Dedicatus on 16/07/2026.
//

import Foundation
import Network

nonisolated enum NetworkWaiter {

    /// Suspends until the default network path is satisfied, or until
    /// `timeout` elapses — whichever comes first. Returns `true` when the
    /// network became (or already was) reachable.
    @discardableResult
    static func waitForConnectivity(timeout: TimeInterval) async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }

        // Continuation must resume exactly once — the path handler, the
        // timeout, or an already-satisfied first update can all race.
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied, gate.claim() {
                    continuation.resume(returning: true)
                }
            }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// One-shot flag: the first `claim()` wins, every later call returns false.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
