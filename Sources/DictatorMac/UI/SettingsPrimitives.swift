import SwiftUI
import AppKit

// Small Settings-window building blocks shared by both mac apps' settings UI.
// They were carved out of Dictator's SettingsView.swift when Dictator Meetings
// became its own app — its Settings window renders the same footnotes, the same
// "This Mac" section headers and the same prompt-customiser editor, and
// duplicating them would let the two drift.
//
// `ThisMacHeader` lost its `private` here; everything else keeps its original
// name and shape.

struct SectionFootnote: View {
    private let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Section header that adds a small "This Mac" chip next to the title.
/// Used only on sections whose settings are per-Mac; synced sections use
/// a plain `Text(...)` header since "synced" is the default.
struct ThisMacHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("This Mac")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .help("Stored in ~/Library/Application Support/Dictator/local-settings.json — per-Mac, doesn't sync to your other Macs.")
    }
}

/// A sentence or two of free text inside a grouped `Form` — instructions,
/// preferences — rendered full width and left-aligned. The obvious
/// `TextField("Label", text:)` in a grouped Form puts the label on the left
/// and trailing-aligns the value, which is right for a name and unreadable
/// for prose. This hides the label (put it in the section header), grows
/// from three to eight lines, then scrolls.
struct InstructionsField: View {
    private let prompt: String
    @Binding private var text: String
    private let onChange: () -> Void

    init(_ prompt: String, text: Binding<String>, onChange: @escaping () -> Void) {
        self.prompt = prompt
        self._text = text
        self.onChange = onChange
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt), axis: .vertical)
            .labelsHidden()
            .lineLimit(3...8)
            .multilineTextAlignment(.leading)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: text) { _, _ in onChange() }
    }
}

/// A full prompt editor for sheets: readable body text (not 11pt monospace),
/// comfortable line spacing, a proper text-area surface. `TextEditor` paints
/// its own background unless `scrollContentBackground` is hidden, which is
/// why earlier rounded backgrounds never showed their corners.
struct PromptEditor: View {
    @Binding var text: String
    var onChange: () -> Void = {}
    var accent: Color? = nil

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder((accent ?? Color.secondary).opacity(accent == nil ? 0.2 : 0.4)))
            .onChange(of: text) { _, _ in onChange() }
    }
}

/// Per-prompt editor. Two modes:
/// - Addendum mode (default): edit a small "Additional instructions" field that
///   gets appended under the built-in at send time.
/// - Override mode: the built-in is replaced entirely with the user's text. A
///   prominent warning explains the risks; a toggle at the bottom flips between
///   modes. The built-in itself lives behind a "View built-in prompt" button
///   that opens a sheet (it's reference material, not edit surface).
struct PromptCustomiser: View {
    let description: String
    let builtin: String
    @Binding var addendum: String
    @Binding var override: String?
    let onChange: () -> Void

    @State private var showBuiltinSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(.init(description))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if override == nil {
                    addendumEditor
                } else {
                    overrideEditor
                }

                Divider()

                HStack(spacing: 16) {
                    Toggle(isOn: Binding(
                        get: { override != nil },
                        set: { isOn in
                            // Seed override with the current built-in on toggle-on, so the
                            // user has something to modify rather than a blank canvas. On
                            // toggle-off we discard the override entirely — the addendum
                            // takes back over.
                            override = isOn ? builtin : nil
                            onChange()
                        }
                    )) {
                        Text("Replace built-in prompt entirely")
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                    Button {
                        showBuiltinSheet = true
                    } label: {
                        Label("View built-in prompt", systemImage: "doc.text")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showBuiltinSheet) {
            BuiltinPromptSheet(prompt: builtin, isPresented: $showBuiltinSheet)
        }
    }

    private var addendumEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional instructions (optional)")
                .font(.subheadline.weight(.medium))
            Text("Appended under the built-in prompt. Use for small personal tweaks — e.g. \"always use British spelling\" or \"never include em-dashes\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            PromptEditor(text: $addendum, onChange: onChange)
                // Same height as the override editor so flipping between addendum
                // and override mode doesn't reflow the pane.
                .frame(height: 300)
            if !addendum.isEmpty {
                HStack {
                    Button("Clear") {
                        addendum = ""
                        onChange()
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var overrideEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Substantive warning: not just "this won't update", but explicit about the
            // failure modes the built-in is engineered to prevent.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Custom override active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text("The built-in prompt contains carefully-tuned rules that prevent common model failures — answering questions instead of transcribing them, leaking conversational preambles, output drifting away from your input. If your custom prompt is missing those rules, you may get **incorrect or unexpected responses**.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text("Future updates to the built-in are often pushed to fix newly-discovered failures. Those won't apply while this override is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))

            Text("Custom prompt (replaces built-in)")
                .font(.subheadline.weight(.medium))
            PromptEditor(text: Binding(
                get: { override ?? "" },
                set: { newValue in
                    override = newValue
                    onChange()
                }
            ), accent: .orange)
            .frame(height: 300)
        }
    }
}

struct BuiltinPromptSheet: View {
    let prompt: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Built-in prompt")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(prompt)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 720, height: 520)
    }
}
