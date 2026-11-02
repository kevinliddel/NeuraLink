//
//  MemoryFootprint.swift
//  NeuraLink
//
//  What the process weighs and how much more it may take before the system
//  ends it: the physical footprint Xcode's gauge shows, the highest it has
//  been since launch, and the kernel's own figure for the bytes still
//  available to this app. Each is read in a few microseconds, so callers
//  can log them beside a heavy load. Memory-mapped files are not in the
//  footprint: their pages are clean and the kernel drops and refetches
//  them as it likes.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import os

enum MemoryFootprint {
    /// Physical footprint in bytes (anonymous, compressed and IOKit memory
    /// charged to the app), or nil when the kernel declines to say.
    nonisolated static var physicalBytes: UInt64? { info()?.phys_footprint }

    /// The highest the physical footprint has been since launch, or nil
    /// where the kernel does not keep the ledger. A step's transient
    /// allocations show here when a reading after the step no longer does.
    nonisolated static var peakPhysicalBytes: UInt64? {
        guard let info = info(), info.ledger_phys_footprint_peak > 0 else { return nil }
        return UInt64(info.ledger_phys_footprint_peak)
    }

    /// Bytes the app may still allocate before the system ends it for
    /// memory, or nil where there is no such limit to report (the simulator).
    nonisolated static var availableBytes: UInt64? {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? UInt64(bytes) : nil
    }

    /// "812 MB" or "?" for a log line.
    nonisolated static func megabytes(_ bytes: UInt64?) -> String {
        bytes.map { "\($0 / 1_048_576) MB" } ?? "?"
    }

    /// "footprint 812 MB (peak 1203 MB)" for a log line.
    nonisolated static var summary: String {
        "footprint \(megabytes(physicalBytes)) (peak \(megabytes(peakPhysicalBytes)))"
    }

    private nonisolated static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
