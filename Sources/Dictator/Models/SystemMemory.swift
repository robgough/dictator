import Foundation

/// Snapshot of the user's machine memory and the model-fit math derived
/// from it. The numbers are baked once at process start — physical RAM
/// doesn't change at runtime — so we can read them freely without locks.
///
/// Two questions the rest of the app asks this:
///
/// 1. "What should we recommend by default?" → `tier`. Drives the wizard's
///    Recommended-LLM preset so we don't silently park 3 GB of weights on
///    an 8 GB Mac.
/// 2. "Will this specific model fit?" → `fit(forModelRAM:)`. Surfaced as a
///    badge on every model row so the cost is visible *before* a download.
///
/// Thresholds are necessarily fuzzy — the user might have Xcode open, might
/// have nothing else running, might be on battery. We err on the side of
/// labelling things "tight" rather than green-lighting and watching a Mac
/// fall into swap.
@MainActor
enum SystemMemory {
    /// Total physical RAM in bytes, as macOS reports it. Cached so callers
    /// don't pay the `ProcessInfo` round-trip on every model row render.
    static let totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    static var totalGB: Double { Double(totalBytes) / 1_073_741_824 }

    /// Human-readable total ("8 GB", "16 GB", "32 GB"). Rounded to the
    /// nearest whole GB because macOS reports values like 8.59 GB on some
    /// configurations and the noise isn't useful.
    static var totalGBLabel: String {
        let rounded = Int(totalGB.rounded())
        return "\(rounded) GB"
    }

    /// Coarse machine-capability bucket. Tiers are intentionally
    /// conservative: 16 GB Macs land in `.balanced` (not `.generous`)
    /// because the user might also be running an IDE, a browser with 40
    /// tabs, and Slack at the same time.
    enum Tier {
        /// ≤ ~12 GB — running a 3B LLM alongside a transcription model
        /// will push the machine into swap. Default to no LLM.
        case lean
        /// ~12–20 GB — comfortable with the 1B LLM. 3B works if not
        /// running much else, but we don't recommend it as the default.
        case balanced
        /// ≥ ~20 GB — fine with the 3B LLM; 7B is the user's call.
        case generous
    }

    /// Machine tier. The cutoffs use `< 12` and `< 20` because reported
    /// physicalMemory on Apple Silicon Macs is slightly under the marketed
    /// number (8 GB MacBooks report ~8.59 GB; 16 GB report ~17.18 GB), and
    /// we don't want a 16 GB machine landing in `.lean` on the wrong side
    /// of an `<= 12` test.
    static var tier: Tier {
        if totalGB < 12 { return .lean }
        if totalGB < 20 { return .balanced }
        return .generous
    }

    /// How a model of `ramMB` resident size fits on this machine. The
    /// fractions assume the user has *other things running too*; the model
    /// doesn't get the whole machine to itself.
    ///
    /// Tuned conservatively:
    /// - `.comfortable` — ≤ 25 % of total RAM. Plenty of headroom.
    /// - `.tight`       — 25–45 %. Will fit, but the OS will start
    ///   evicting other apps' pages under load.
    /// - `.tooLarge`    — > 45 %. Strongly inadvisable; on smaller Macs
    ///   this means active swap-thrash the moment another app gets busy.
    enum Fit: Equatable {
        case comfortable
        case tight
        case tooLarge
    }

    static func fit(forModelRAM ramMB: Int) -> Fit {
        let ramBytes = Double(ramMB) * 1_048_576
        let fraction = ramBytes / Double(totalBytes)
        if fraction < 0.25 { return .comfortable }
        if fraction < 0.45 { return .tight }
        return .tooLarge
    }

    /// Combined fit of a transcription + LLM pair, since users normally
    /// run both side-by-side and the recommendation has to account for
    /// the sum. Worst component wins.
    static func fit(transcriptionRAM: Int, llmRAM: Int) -> Fit {
        let combined = transcriptionRAM + llmRAM
        return fit(forModelRAM: combined)
    }
}
