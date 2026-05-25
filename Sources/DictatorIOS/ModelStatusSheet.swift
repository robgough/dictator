import SwiftUI

/// Sheet presented when the user taps the model-status chip on the main
/// recording screen. Shows the current model's name, in-memory status,
/// and on-disk footprint; exposes an explicit Unload action so users
/// can reclaim ~500 MB when they know they won't dictate for a while.
///
/// Re-downloading or deleting from disk are deliberately not exposed
/// here — they're power-user paths that warrant a confirmation flow
/// and aren't worth the surface area in a prototype that has no model
/// picker yet.
struct ModelStatusSheet: View {
    @Bindable var viewModel: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Model", value: Self.displayName(for: viewModel.selectedModelID))
                    LabeledContent("Status", value: statusText)
                    LabeledContent("Disk size", value: "~460 MB")
                } footer: {
                    Text(footerText)
                }

                if viewModel.isModelLoaded {
                    Section {
                        Button(role: .destructive) {
                            viewModel.unloadModel()
                            dismiss()
                        } label: {
                            Label("Unload from memory", systemImage: "arrow.up.bin")
                        }
                    } footer: {
                        Text("Frees the memory the model is holding. It'll automatically reload the next time you press the mic — same files, just a brief warm-up delay (~5-15 s).")
                    }
                }
            }
            .navigationTitle("Transcription Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        if viewModel.isModelLoading { return "Loading…" }
        if viewModel.isModelLoaded { return "Loaded in memory" }
        return "On disk · not loaded"
    }

    private var footerText: String {
        // Inline rationale for the user — the model runs locally on
        // the ANE, no network involved after the initial download.
        // Surfaces the "your audio doesn't leave the device" promise
        // that matters most for a dictation app.
        "The Parakeet model runs entirely on-device on the Apple Neural Engine. Your audio never leaves this device."
    }

    /// Human-readable label for a Parakeet catalogue ID. Keeps the
    /// "Parakeet TDT 0.6B" stem identical across variants so the only
    /// difference the user sees is the version suffix — matches the
    /// picker labels in Settings and the download CTA.
    static func displayName(for modelID: String) -> String {
        switch modelID {
        case "parakeet-tdt-0.6b-v3": return "Parakeet TDT 0.6B (v3)"
        case "parakeet-tdt-0.6b-v2": return "Parakeet TDT 0.6B (v2)"
        default: return modelID
        }
    }
}
