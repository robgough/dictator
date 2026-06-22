import SwiftUI

/// The keyboard's SwiftUI layout. Two big buttons (red mic, purple
/// assist) plus a tiny secondary row with Undo / Return / Backspace.
/// The Dictate / Assist buttons just open the host app and start it
/// listening — recording happens in Dictator's foreground (we don't
/// run a background audio mode), so the keyboard never renders an
/// in-flight recording UI. When the transcript lands it's auto-copied
/// to the clipboard and the user drops it in with the always-on Paste
/// pill.
struct KeyboardRootView: View {
    let onMicPress: () -> Void
    let onAssistPress: () -> Void
    let onUndo: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    /// True when the host device + iOS Settings combination can
    /// actually run Apple Intelligence. When false we hide the
    /// Assist button entirely — older iPhones (pre-15 Pro) will
    /// never get an Assist that works, so dangling it disabled is
    /// worse than hiding it. The Settings screen in the host app
    /// explains why.
    let assistSupported: Bool
    /// True when there's text before the cursor for assist to
    /// transform. When false the Assist button greys out — tapping
    /// it with an empty field would launch the host with nothing to
    /// act on, which silently does nothing and looks broken.
    let canAssist: Bool
    /// Backspace uses press / release callbacks rather than a single
    /// tap action so the controller can run a hold-to-repeat timer
    /// (char delete after a short delay, escalating to word delete
    /// after a longer hold).
    let onBackspacePress: () -> Void
    let onBackspaceRelease: () -> Void
    let canUndo: Bool
    /// True when the system clipboard has a string to paste. Drives
    /// the always-on Paste pill's enabled state.
    let canPaste: Bool
    /// Text the keyboard renders in the preview pill alongside
    /// Paste. Sourced from the host's last-dictation snapshot via
    /// the App Group; `nil` when the system clipboard has been
    /// overwritten by another app since the host wrote (or the host
    /// hasn't transcribed yet on this device). We never read
    /// `UIPasteboard.general.string` for this — that would trip
    /// iOS's "Pasted from X" toast / permission prompt.
    let pastePreview: String?
    /// Tap action for the always-on Paste pill. Reads from
    /// `UIPasteboard.general` and inserts via the text document
    /// proxy — see `KeyboardViewController.pasteFromClipboard`.
    let onPaste: () -> Void

    /// True while the "copy text first" hint is on screen. Set when
    /// the user taps a greyed-out Assist button; auto-clears after a
    /// few seconds via `hintHideTask`, and also clears the moment
    /// `canAssist` flips true (a fresh copy made the prompt moot).
    @State private var showAssistHint = false
    @State private var hintHideTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            // Always-on Paste pill above whatever primary content is
            // showing. Enabled only when the system clipboard has a
            // string; tap reads it and inserts via the text document
            // proxy.
            pasteChip

            if showAssistHint && !canAssist && assistSupported {
                // Hint takes over the same slot as Dictate / Assist —
                // a clean swap at matched height rather than pushing
                // the secondary row off the bottom of the keyboard.
                // Auto-reverts after the hide task fires. We never
                // surface the hint when assist isn't supported — the
                // Assist button itself is hidden in that case so
                // there's no greyed control for the user to prod.
                assistHintBanner
            } else {
                idleContent
            }

            secondaryRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .animation(.easeInOut(duration: 0.2), value: showAssistHint)
        // Once the user copies something the gate opens and the
        // hint becomes redundant — clear it (and cancel any pending
        // auto-hide) so it doesn't linger while Assist is live.
        .onChange(of: canAssist) { _, newValue in
            if newValue {
                hintHideTask?.cancel()
                hintHideTask = nil
                showAssistHint = false
            }
        }
    }

    /// Replacement for the Dictate / Assist row while the user has
    /// tapped the disabled "Copy first" button. Same height (56pt)
    /// as the buttons it replaces so the rest of the keyboard layout
    /// doesn't reflow.
    private var assistHintBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Copy text first")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Highlight and copy in your app, then tap Assist.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .transition(.opacity)
    }

    // MARK: - Idle (no in-flight session)

    @ViewBuilder
    private var idleContent: some View {
        HStack(spacing: 24) {
            primaryButton(
                tint: .red,
                icon: "mic.fill",
                label: "Dictate",
                action: onMicPress,
                enabled: true
            )
            if assistSupported {
                // Assist reads the system clipboard for the text to
                // transform (selectedText is unreliable across iOS
                // apps — see KeyboardViewController). When there's
                // nothing fresh to act on, the button looks disabled
                // (greyed, "Copy first" label) but stays tappable so we
                // can pop a hint explaining what to do — a true
                // SwiftUI .disabled() button can't fire any action,
                // which leaves the user prodding a dead control.
                Button {
                    if canAssist {
                        onAssistPress()
                    } else {
                        showAssistHint = true
                        hintHideTask?.cancel()
                        hintHideTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            showAssistHint = false
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: canAssist ? "wand.and.stars" : "doc.on.clipboard")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(canAssist ? "Assist" : "Copy first")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.purple)
                    )
                    .opacity(canAssist ? 1 : 0.4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Paste row (always-on shortcut for the system clipboard)

    /// Paste button on the left + preview pill on the right.
    /// Reads `UIPasteboard.general.string` and inserts via the text
    /// document proxy on tap; greys out when the clipboard is empty.
    /// The preview only shows when we can verify the clipboard still
    /// holds the host's last-dictation snapshot (we compare
    /// changeCount through the App Group) — that way "Hello world"
    /// doesn't keep advertising itself after the user has copied
    /// something unrelated from another app.
    @ViewBuilder
    private var pasteChip: some View {
        // Both halves share a fixed height (36pt) and cornerRadius 10
        // so they read as the same shape family as the secondary-row
        // tiles (Undo / Space / Return / Backspace are also 10pt
        // radius). The previous cornerRadius 14 looked pill-shaped on
        // such a short element — 14 reads as "rounded rectangle" on
        // the 56pt-tall Dictate / Assist tiles, but on a 24pt-tall
        // chip the corners are nearly half the height and the whole
        // thing collapses to a capsule.
        let chipHeight: CGFloat = 36
        let chipCornerRadius: CGFloat = 10
        HStack(spacing: 8) {
            Button(action: onPaste) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.caption.weight(.semibold))
                    Text(canPaste ? "Paste" : "Nothing to paste")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(canPaste ? Color.accentColor : .secondary)
                .padding(.horizontal, 12)
                .frame(height: chipHeight)
                .glassEffect(.regular, in: .rect(cornerRadius: chipCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(!canPaste)

            // Always render the preview pill so the row has a stable
            // shape — an empty trailing Spacer made the right half of
            // the keyboard look broken when the user hadn't copied
            // anything yet, or after another app had overwritten the
            // clipboard. Three states for the copy: the preview
            // itself if we have it; an honest "from another app"
            // when there's something pasteable but no snippet (we
            // can't peek into the clipboard string without triggering
            // iOS's "Pasted from X" toast, so we only get a snippet
            // when Dictator was the one who wrote); and "nothing on
            // the clipboard" when there's nothing to paste at all.
            previewPill(height: chipHeight, cornerRadius: chipCornerRadius)
        }
    }

    @ViewBuilder
    private func previewPill(height: CGFloat, cornerRadius: CGFloat) -> some View {
        // Three flavours of pill content, kept terse and parallel so
        // the row reads cleanly at a glance. We deliberately don't say
        // "from another app" for the no-snippet case — it framed the
        // message from Dictator's perspective ("not us") and confused
        // users who'd just copied something in the host app; the
        // shorter "Ready" sidesteps the framing entirely. "Empty" is
        // similarly the shortest honest answer when there's nothing to
        // paste at all.
        HStack(spacing: 6) {
            if let preview = pastePreview {
                Text(previewSnippet(preview))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("· \(wordCount(preview)) words")
                    .foregroundStyle(.tertiary)
            } else if canPaste {
                Image(systemName: "doc.on.clipboard")
                    .font(.caption2)
                Text("Ready")
                    .lineLimit(1)
            } else {
                Image(systemName: "tray")
                    .font(.caption2)
                Text("Empty")
                    .lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// Single-line snippet for the preview pill — collapses
    /// whitespace and trims so a multi-paragraph transcript still
    /// reads cleanly at one line width.
    private func previewSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Secondary row

    @ViewBuilder
    private var secondaryRow: some View {
        // No internal horizontal padding — the parent VStack already
        // applies 16pt, and stacking a second pass made this row sit
        // visibly more inset than the paste / idle / in-flight rows
        // above it.
        HStack(spacing: 10) {
            secondaryButton(
                icon: "arrow.uturn.backward",
                label: "Undo",
                action: onUndo,
                enabled: canUndo
            )
            spaceBarButton
            secondaryButton(
                icon: "return",
                label: "Return",
                action: onReturn,
                enabled: true
            )
            backspaceButton
        }
    }

    /// Wide space-bar tile that fills the gap between Undo and
    /// Return. Width-flex via `maxWidth: .infinity` so the fixed
    /// 60 pt tiles on either side stay put and the spacebar
    /// absorbs the remaining row.
    private var spaceBarButton: some View {
        Button(action: onSpace) {
            Text("space")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Space")
    }

    // MARK: - Backspace (tap = one char, hold = repeat)

    /// Press-and-hold backspace. Same visual shape as the other
    /// secondary tiles but driven by a long-press gesture so the
    /// controller can repeat-delete while the user holds. Tap-only
    /// users get a single delete on press-then-quick-release because
    /// the controller fires `deleteBackward()` immediately on press.
    @State private var backspacePressed = false

    private var backspaceButton: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 60, height: 44)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .scaleEffect(backspacePressed ? 0.95 : 1)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: backspacePressed)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                // Tap-completion handler; press / release fire via
                // onPressingChanged so the repeat timer can engage.
            } onPressingChanged: { pressing in
                if pressing, !backspacePressed {
                    backspacePressed = true
                    onBackspacePress()
                } else if !pressing, backspacePressed {
                    backspacePressed = false
                    onBackspaceRelease()
                }
            }
            .accessibilityLabel("Backspace")
    }

    // MARK: - Building blocks

    private func primaryButton(
        tint: Color,
        icon: String,
        label: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                    .font(.callout.weight(.semibold))
            }
            // Glass face with a tinted label/icon (matches the app's record
            // buttons). `.opacity` can't fade glass, so the tint carries the
            // disabled state.
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Icon-only tile. The previous label-and-text layout was
    /// wrapping "Backspace" mid-word on narrower iPhones; this
    /// version drops the text (still readable from the icon) and
    /// bumps the vertical size to a comfortable tap target. The
    /// `label` parameter is retained for VoiceOver via
    /// `accessibilityLabel` so screen-reader users get the same
    /// affordance.
    private func secondaryButton(
        icon: String,
        label: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                // Fade the icon (not the glass — `.opacity` doesn't affect a
                // glassEffect) to signal the disabled state.
                .foregroundStyle(.primary.opacity(enabled ? 1 : 0.35))
                .frame(width: 60, height: 44)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
