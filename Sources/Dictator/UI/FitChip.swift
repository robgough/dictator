import SwiftUI

/// Small badge that shows whether a model's RAM cost is a comfortable fit
/// on the user's Mac. Used in the wizard's `ModelDownloadCard` and the
/// Settings Models pane's `ModelRow` so the same signal travels with the
/// model wherever it appears.
///
/// We never *block* a download — the user might know what they're doing
/// (e.g. only running Dictator on the machine) — but we make the cost
/// visible. Tooltips spell out the percentage of system RAM the model
/// would claim, so the chip's colour isn't the only signal.
struct FitChip: View {
    let ramMB: Int

    private var fit: SystemMemory.Fit {
        SystemMemory.fit(forModelRAM: ramMB)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .help(tooltip)
    }

    private var label: String {
        switch fit {
        case .comfortable: "Fits"
        case .tight:       "Tight"
        case .tooLarge:    "Too large"
        }
    }

    private var tint: Color {
        switch fit {
        case .comfortable: .green
        case .tight:       .orange
        case .tooLarge:    .red
        }
    }

    private var tooltip: String {
        let total = SystemMemory.totalGBLabel
        let modelGB = Double(ramMB) / 1024
        let modelLabel: String = ramMB >= 1024
            ? String(format: "%.1f GB", modelGB)
            : "\(ramMB) MB"
        switch fit {
        case .comfortable:
            return "This model uses about \(modelLabel) of RAM — comfortable on your \(total) Mac."
        case .tight:
            return "This model uses about \(modelLabel) of RAM — tight on your \(total) Mac. macOS will start evicting other apps' pages under load."
        case .tooLarge:
            return "This model uses about \(modelLabel) of RAM — too large for your \(total) Mac to run smoothly alongside other apps. Expect swap-thrash."
        }
    }
}
