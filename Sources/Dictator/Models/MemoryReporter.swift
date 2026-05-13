import Foundation
import Darwin.Mach

/// Snapshot of the device's physical RAM and the app's current resident set
/// size. Both fields are at the time of read — `MemoryReporter.read()` is the
/// only producer.
struct MemoryReading: Equatable, Sendable {
    let physicalBytes: UInt64
    let residentBytes: UInt64

    static let zero = MemoryReading(physicalBytes: 0, residentBytes: 0)

    /// Physical RAM in megabytes (decimal, like macOS's "About this Mac"
    /// figures — 16 GB shows as 16000 MB, not 16384).
    var physicalMB: Int { Int(physicalBytes / 1_000_000) }

    /// Resident set size in megabytes. Same decimal convention.
    var residentMB: Int { Int(residentBytes / 1_000_000) }
}

enum MemoryReporter {
    /// Reads physical memory from `ProcessInfo` and the app's resident set
    /// size via Mach's `task_info(MACH_TASK_BASIC_INFO)`. Cheap — both calls
    /// are non-blocking kernel reads. Safe to call on the main thread on a
    /// timer.
    ///
    /// Note: `resident_size` is *physical* pages currently mapped to our
    /// process. macOS aggressively compresses cold pages, so this number
    /// can be lower than the model weights on disk and still represent the
    /// model being usable — uncompressed pages are pulled back lazily.
    static func read() -> MemoryReading {
        let physical = ProcessInfo.processInfo.physicalMemory

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        let resident: UInt64 = (kr == KERN_SUCCESS) ? info.resident_size : 0
        return MemoryReading(physicalBytes: physical, residentBytes: resident)
    }
}
