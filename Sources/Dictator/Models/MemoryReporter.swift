import Foundation
import Darwin.Mach

/// Snapshot of the device's physical RAM and the app's current resident set
/// size. Both fields are at the time of read — `MemoryReporter.read()` is the
/// only producer.
struct MemoryReading: Equatable, Sendable {
    let physicalBytes: UInt64
    let residentBytes: UInt64

    static let zero = MemoryReading(physicalBytes: 0, residentBytes: 0)

    /// Human-readable physical RAM, formatted to match Apple's "About This
    /// Mac" / Activity Monitor convention (binary gigabytes labelled "GB").
    /// A 64 GiB machine reads back as 68,719,476,736 bytes — divided by
    /// 10⁹ that's 68.7, divided by 2³⁰ it's 64. We display the binary
    /// value to avoid the "I have 64 GB but Dictator says 68.7" surprise.
    var physicalDisplay: String { Self.formatBinary(physicalBytes) }

    /// Resident set size, formatted with the same binary convention as
    /// `physicalDisplay`. Lines up with Activity Monitor's reading.
    var residentDisplay: String { Self.formatBinary(residentBytes) }

    private static func formatBinary(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824 // 2³⁰
        if gib >= 1 {
            // Snap to an integer for whole-gigabyte machine totals (8, 16,
            // 32, 64), use one decimal otherwise so resident readings still
            // show movement.
            if abs(gib.rounded() - gib) < 0.05 {
                return "\(Int(gib.rounded())) GB"
            }
            return String(format: "%.1f GB", gib)
        }
        let mib = Double(bytes) / 1_048_576 // 2²⁰
        return "\(Int(mib.rounded())) MB"
    }
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
