# Dictator

Tiny native macOS dictation app. Hold a hotkey, talk, release — Dictator transcribes locally with [WhisperKit](https://github.com/argmaxinc/WhisperKit), runs the text through one to three small local-LLM passes ([MLX Swift](https://github.com/ml-explore/mlx-swift-examples)) to format punctuation / "new line" / named emojis, optionally tidy grammar and restructure into paragraphs/lists, then pastes the result into the focused app.

This repo also builds **Dictator Meetings**, a separate windowed app for recording calls and writing meeting notes on-device — see `Sources/DictatorMeetings/`. It's a distinct scheme, bundle ID, and release channel from Dictator; the two apps share code (not a compiled framework — each gets its own copy) under `Sources/DictatorMac/` and `Sources/DictatorCore/`, and Dictator can share its already-loaded LLM with Meetings over a local socket rather than both apps holding a copy in memory.

Apple Silicon only. Built and tested on macOS 26.

## Build

```bash
brew install xcodegen

# Copy the env template and fill in your 10-char Apple Personal Team ID.
# (Find it in Xcode → Settings → Accounts → your Apple ID, or via `codesign -dv`
# on any Mac app you've signed.) `.env` is gitignored.
cp .env.example .env
$EDITOR .env

# Regenerate the Xcode project. `./gen` is a wrapper that sources `.env` first
# so xcodegen sees DICTATOR_TEAM_ID; calling `xcodegen generate` directly works
# too, but only if you've exported the variable in your shell.
./gen

open Dictator.xcodeproj   # then ⌘R the "Dictator" scheme (dictation),
                          # or switch to "DictatorMeetings" for the notes app
```

Without `DICTATOR_TEAM_ID` set, the app still builds — Xcode falls back to ad-hoc signing. The trade-off: you'll be re-prompted for Microphone and Accessibility permission after every Clean Build Folder, because TCC can't anchor the grants to a stable identity.

A post-build phase also installs a re-signed copy of the `.app` to `~/Applications/Dictator.app`. Launching from that stable path keeps TCC grants stable across rebuilds; ⌘R from Xcode also works fine once the team ID is set.

Xcode resolves four SPM packages on first build:

- `argmaxinc/WhisperKit` — speech-to-text
- `ml-explore/mlx-swift-examples` — MLX LLM runtime (pinned to commit `eb76c5b7` so its `swift-transformers` requirement overlaps with WhisperKit's)
- `sindresorhus/KeyboardShortcuts` — global hotkey + recorder UI
- transitive: `huggingface/swift-transformers`, `apple/swift-numerics`, …

You'll also be prompted once to install the Metal Toolchain (~688 MB) — MLX needs it to compile its kernels.

Models are **not** bundled — download them on first run from **Settings → Models**. They land in `~/Library/Application Support/Dictator/Models/`.

## First-run permissions

On first run macOS will prompt for:

1. **Microphone** — needed to record audio.
2. **Accessibility** — needed to synthesise ⌘V into the focused app. If you skip this Dictator still copies the result to the clipboard and shows a hint in the HUD.

System Settings → Privacy & Security → Accessibility → add `Dictator.app` if the prompt doesn't appear. Settings → General → Permissions shows the current Accessibility status with a one-click jump to the right pane.

## Usage

1. Click the menu-bar icon → **Settings…**
2. **Models** tab → download one Whisper model + one LLM model. Defaults:
   - Whisper Small (English) — 470 MB
   - Llama 3.2 3B Instruct (4-bit) — 1.9 GB
3. **General** tab → choose your trigger:
   - **Keyboard combination** (default ⌥⌘D, fully customisable) — hold to record, release to transcribe.
   - **Modifier-only** (Right Option, Right Command, fn, …) — distinguishes left vs right via key code.
4. Optional passes in **General → Behaviour**:
   - **Tidy grammar** — runs an extra LLM pass that fixes obvious grammar errors (contractions, agreement, duplicate words). Validated by word-level edit distance.
   - **Restructure long dictations** — paragraph breaks and bullet lists for transcripts above a word threshold. Validated by strict word-sequence equality.
   - **Pre-load models on launch** — warm both models into memory at startup so the first hotkey press is instant (costs ~3 GB resident).
5. **Input** tab → ordered list of every input device you've seen, with drag-to-reorder priority, live connected/disconnected indicators, and per-device "forget".
6. **Dictionary** tab → custom spellings / corrections applied deterministically right after the formatter pass. Whole-word and case-sensitivity per entry.
7. **Prompt** tab → edit any of the three pass prompts; each has its own "Reset to default".
8. **History** tab → last 7 days / 500 dictations, each expandable to show every stage of the pipeline with per-stage copy buttons.

The menu-bar dropdown also shows a Recent list (last 10) — click a row to copy its final text.

## Pipeline

```
Hotkey (KeyboardShortcuts or NSEvent flagsChanged)
   │  hold / release
   ▼
AudioRecorder (AVAudioEngine, fresh engine per session, preferred device
   pinned via kAudioOutputUnitProperty_CurrentDevice)
   │  on release: [Float] samples (16 kHz mono)
   ▼
TranscriptionService (WhisperKit 0.18)
   │  raw transcript
   ▼
Pass 1 — Format (MLX, strict prompt, deterministic temperature=0)
   │  formatted text
   ▼
Dictionary — case-insensitive whole-word substitutions
   │  corrected text
   ▼
Pass 2 — Grammar (optional, MLX, validated by word-level Levenshtein)
   │  tidied text
   ▼
Pass 3 — Structure (optional, MLX, validated by word-sequence equality)
   │  final text
   ▼
TextInjector (NSPasteboard + synthetic ⌘V via CGEvent) — or
   clipboard-only fallback if Accessibility isn't granted
   │
   ▼
DictationHistory (JSON at ~/Library/Application Support/Dictator/history.json)
```

The whole flow is driven by the `Pipeline` state machine, which the floating `HUDPanel` observes for live waveform / status / device-name / result display.

## Why some of the moving parts exist

- **`ditto` in the post-build phase**: `cp -R` doesn't reliably preserve code-signature metadata on app bundles. `ditto` does.
- **Re-signing the installed copy in the post-build phase**: xcodegen's `postBuildScripts` run *before* Xcode's `CodeSign` phase, so the freshly-copied `.app` would otherwise be unsigned.
- **`mlx-swift-examples` pinned to commit `eb76c5b7`**: later commits require `swift-transformers ≥1.3`, which conflicts with WhisperKit 0.18's cap at `<1.2`. That commit is the last one on the compatible line.
- **Closures on the audio thread are explicitly `@Sendable`**: Swift 6 otherwise treats them as `@MainActor`-isolated because they're declared inside `@MainActor` methods, and dispatch traps the moment AVAudioEngine invokes them from its realtime audio queue.
- **`format: nil` in `installTap`**: setting the audio device via `AudioUnitSetProperty` doesn't always update the input node's reported format synchronously, so caching the format and passing it explicitly leads to `Failed to create tap due to format mismatch`. Passing `nil` lets AVAudioEngine pull the actual current format.
