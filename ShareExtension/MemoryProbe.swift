import Darwin
import Foundation
import os

/// Lightweight memory sampling for the share-extension spike.
///
/// The share extension is jetsammed when its physical footprint approaches the
/// 120 MB ceiling. `os_proc_available_memory()` reports how many more bytes the
/// process may allocate before that happens, which is the signal the spike
/// records across boot -> prepare -> publish.
enum MemoryProbe {
    /// Bytes the process may still allocate before iOS kills it for memory.
    /// Returns nil when the platform cannot report a limit.
    static var availableBytes: Int? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let value = os_proc_available_memory()
        return value > 0 ? value : nil
        #else
        return nil
        #endif
    }

    /// Resident physical footprint in bytes (what counts against the cap).
    static var footprintBytes: UInt64? {
        var info = task_vm_info_data_t()
        let stride = MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func megabytes(_ bytes: some BinaryInteger) -> String {
        let value = Double(bytes) / (1024 * 1024)
        return String(format: "%.1f MB", value)
    }

    /// Human-readable snapshot for a log line, e.g. "footprint=42.3 MB available=78.0 MB".
    static var snapshot: String {
        let footprint = footprintBytes.map { megabytes($0) } ?? "n/a"
        let available = availableBytes.map { megabytes($0) } ?? "n/a"
        return "footprint=\(footprint) available=\(available)"
    }
}
