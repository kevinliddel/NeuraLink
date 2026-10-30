//
//  MemoryFootprint.swift
//  NeuraLink
//
//  What the process weighs and how much more it may take before the system
//  ends it: the physical footprint Xcode's gauge shows, and the kernel's
//  own figure for the bytes still available to this app. Both are read in
//  a few microseconds, so callers can log them beside a heavy load.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import os

enum MemoryFootprint {
    /// Physical footprint in bytes (anonymous, compressed and IOKit memory
    /// charged to the app), or nil when the kernel declines to say.
    nonisolated static var physicalBytes: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
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
}
