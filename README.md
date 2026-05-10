# Dictator

Tiny native macOS dictation app. Hold a hotkey, talk, release — Dictator transcribes locally with [WhisperKit](https://github.com/argmaxinc/WhisperKit), runs the text through a small local LLM ([MLX Swift](https://github.com/ml-explore/mlx-swift-examples)) to format punctuation / "new line" / named emojis, then pastes the result into the focused app.

Apple Silicon only. Built and tested on macOS 26.

## Build

```bash
# One-time:
brew install xcodegen
xcodegen generate

# Open in Xcode and Run (⌘R):
open Dictator.xcodeproj
```

Xcode resolves three SPM packages on first build:

- `argmaxinc/WhisperKit` — speech-to-text
- `ml-explore/mlx-swift-examples` — MLX LLM runtime
- `sindresorhus/KeyboardShortcuts` — global hotkey + recorder UI

Models are **not** bundled — they're downloaded on demand from the **Models** tab in Settings, into `~/Library/Application Support/Dictator/Models/`.

## First-run permissions

On first run macOS will prompt for:

1. **Microphone** — needed to record audio.
2. **Accessibility** — needed to synthesise ⌘V into the focused app. If you skip this Dictator still copies the result to the clipboard.

If the Accessibility prompt doesn't appear: System Settings → Privacy & Security → Accessibility → add `Dictator.app`.

## Usage

1. Open the menu-bar icon → **Settings…**
2. **Models** tab → Download one Whisper model + one LLM model. Recommended defaults:
   - Whisper Small (English) — 470 MB
   - Llama 3.2 3B Instruct (4-bit) — 1.9 GB
3. **General** tab → set your hotkey (default: ⌥⌘D). Hold = recording, release = transcribe + format + paste.
4. **Prompt** tab → tweak the formatting prompt.

The HUD appears at the bottom-centre of the focused screen while a dictation is in flight.

## Architecture

```
Hotkey (KeyboardShortcuts)
       │  hold / release
       ▼
AudioRecorder (AVAudioEngine → 16kHz mono Float32)
       │  on release: [Float] samples
       ▼
TranscriptionService (WhisperKit)
       │  raw text
       ▼
LLMService (MLX Swift, Llama 3.2 / Qwen 2.5)
       │  formatted text
       ▼
TextInjector (NSPasteboard + synthetic ⌘V via CGEvent)
```

The `Pipeline` actor is the state machine driving the floating `HUDPanel`.
