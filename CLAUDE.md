# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dictator is a menu-bar macOS dictation app. Hold a hotkey → record → transcribe locally (WhisperKit or Parakeet/FluidAudio) → optionally pipe through 1–3 MLX-Swift LLM passes (format, grammar, restructure) → paste into the focused app via synthetic ⌘V. Apple Silicon only, macOS 15+, all inference on-device.

A second mode (Assistant Mode, separate hotkey) grabs the current selection, takes a spoken instruction, and either replaces the selection in-place or copies a drafted reply to the clipboard.

## Build & run

```bash
brew install xcodegen
cp .env.example .env && $EDITOR .env   # add DICTATOR_TEAM_ID
./gen                                  # regenerate Dictator.xcodeproj
open Dictator.xcodeproj                # then ⌘R
```

`./gen` sources `.env` before invoking `xcodegen`. `xcodegen generate` works too, but only if the env vars are already exported. `Dictator.xcodeproj` is gitignored — it's a generated artifact from `project.yml`.

**CLI builds** (useful for headless verification): set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the system has `xcode-select` pointed at CommandLineTools by default, which lacks `xcodebuild`), then `xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -derivedDataPath .derivedData build`. A post-build phase installs the signed `.app` to `~/Applications/Dictator.app`.

No test target exists. There is no lint config.

### Code signing & macOS TCC

TCC (Privacy & Security grants for Mic / Accessibility) keys grants by *signed identity*. Ad-hoc signing (`codesign --sign -`) produces a different signature on every rebuild, so the OS forgets the grant each time. Three optional env vars pin to a real Apple Development cert:

- `DICTATOR_TEAM_ID` — your 10-char team ID
- `DICTATOR_CODE_SIGN_IDENTITY` — SHA-1 of your cert from `security find-identity -v -p codesigning`
- `DICTATOR_CODE_SIGN_STYLE=Manual` — automatic style needs GUI provisioning that CLI builds can't trigger

When any of the three is unset, the build falls back to ad-hoc (still works, but TCC grants don't survive rebuilds). Sandbox is disabled in `Dictator.entitlements`, so no provisioning profile is required.

The post-build phase ditto-copies the built `.app` to `~/Applications/Dictator.app` and re-signs it with the same identity. Two non-obvious reasons:
- `cp -R` doesn't preserve code-signature metadata; `ditto` does.
- xcodegen's `postBuildScripts` run *before* Xcode's `CodeSign` phase, so the ditto'd copy is unsigned at that moment and needs an explicit `codesign` invocation.

## Architecture

Everything runs on the main actor unless explicitly hopped off it. Concurrency is `SWIFT_STRICT_CONCURRENCY=minimal` but Swift 6 still enforces actor isolation on closures — see "Swift 6 gotchas" below.

### The Pipeline state machine

`Pipeline/Pipeline.swift` (`@MainActor @Observable`) owns the state machine the whole UI observes:

```
.idle → .capturingSelection? → .recording → .transcribing → .formatting →
.fixingGrammar? → .restructuring? → .assisting? → .compacting? → .done → .idle
                                                                       ↘ .failed
```

`.capturingSelection`, `.assisting`, `.compacting` only fire in Assistant Mode. `.fixingGrammar` and `.restructuring` are optional dictation passes gated by settings + word count.

The two entry points (`startRecording` / `finishRecording` and `startAssistant` / `finishAssistant`) live on the same `Pipeline` instance so the HUD panel and menu bar can render either path off the same observed state.

### Two transcription engines behind one protocol

`Transcription/ASREngine.swift` is the small surface (`download`, `ensureLoaded`, `unload`, `transcribe`, `currentModelID`, `isLoading`) both `TranscriptionService` (WhisperKit) and `ParakeetService` (FluidAudio CoreML on the ANE) conform to. Pipeline holds both and dispatches via `activeASR` based on `settings.transcriptionEngine`. The protocol omits WhisperKit's `prompt:` arg deliberately — prompt biasing is parked (see `whisper_prompt_biasing.md` in auto-memory), and Parakeet has no equivalent.

Each engine's weights live under `~/Library/Application Support/Dictator/Models/{whisper,parakeet,llm}/<id>/`. `ModelStorage` is the single source of truth for these paths. FluidAudio is given an explicit `to:` URL so it doesn't fall back to its default `~/Library/Application Support/FluidAudio/Models/...` location.

### Pass validation (the "did the LLM go off the rails?" guard)

Each LLM pass has a deterministic post-check; the pipeline reverts to the previous stage's output if the check fails. This is the whole reason small local LLMs are tolerable here.

- **Pass 1 (Format)**: question-shaped input (trailing `?` or interrogative first word) skips Pass 1 entirely — Whisper already punctuates correctly and small models are biased toward *answering* questions rather than transcribing them. For everything else, `Pipeline.passOnePreservesContent` validates that ≥60% of input anchor words (≥4 chars, not punctuation triggers) survive in the output AND the word count didn't grow more than 15% + 3. Failure → fall back to raw Whisper transcript with a HUD note.
- **Pass 2 (Grammar)**: word-level Levenshtein distance. Reverts if drift exceeds `settings.grammarPassMaxEditFraction` (default 0.15).
- **Pass 3 (Structure)**: strict word-sequence equality after lowercasing/stripping non-alphanumerics. Reverts on any word change — bullets/breaks only.

The `Vocabulary` substitution pass runs between Pass 1 and Pass 2, deterministic case-insensitive whole-word replace.

### Prompt customisation model

`Settings/DictatorSettings.swift` has a built-in prompt per pass (source of truth, not editable), an `…PromptAddendum` (appended under a labelled header — for "always use British spelling" tweaks), and an `…PromptOverride` (full replacement — escape hatch, addendum ignored). `effectiveXxxPrompt` resolves these.

The assistant prompt additionally substitutes `{{USER_NAME}}` in its few-shot examples at runtime — small models copy the *shape* of examples far more reliably than they obey abstract rules, so the user's actual name in the example signatures stops "[Your Name]" placeholders from leaking into drafted emails.

### Audio capture

`Audio/AudioRecorder.swift` recreates `AVAudioEngine` on every `start()`. Reusing the engine after a device override can leave the AUHAL in an unstable state (`kAudioUnitErr_FormatNotSupported`). The preferred input device comes from `AudioDeviceManager`, which keeps an ordered list per machine; if `engine.start()` fails with the override, the recorder transparently retries on the system default.

Mid-recording device changes (AirPods connect, USB mic unplugged, hub power-cycle) fire `AVAudioEngineConfigurationChange`. The handler discards the buffer (old + new device usually have different rates) and silently restarts on whatever input is active now, instead of dumping the user back to the HUD with an error.

### Text injection

`Injection/TextInjector.swift` uses `NSPasteboard` + synthetic ⌘V via `CGEvent`. The pre-paste selection range is captured via `AXUIElement` so Assistant Mode's REPLACE flow can re-select what it just pasted (lets the user re-prompt the assistant on the inserted text).

Falls back to clipboard-only if Accessibility isn't granted; the HUD surfaces the reason. `focusedElementIsEditableText()` gates REPLACE-mode pastes so we don't dump assistant output into a URL bar or somewhere it wasn't meant to go.

### Service holders pattern

`Services/ServiceHolders.swift` exposes shared singletons (`TranscriptionServiceHolder`, `ParakeetServiceHolder`, `LLMServiceHolder`) as `@MainActor enum` with a single `static let shared`. Pipeline and Settings both reach for the same instance — model loads are amortised across UI and dictation paths.

## Swift 6 gotchas baked into the code

These are non-obvious and load-bearing — don't "clean up" without understanding why:

- **`@Sendable` on audio-thread closures**: `AVAudioEngine.installTap` invokes its block on the realtime audio queue. Without `@Sendable`, Swift 6 inherits `@MainActor` isolation from the enclosing method and dispatch traps the moment the audio thread fires the closure. See `AudioRecorder.configureAndStartEngine`.
- **`format: nil` in `installTap`**: `outputFormat(forBus:)` returns a stale format right after `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice, ...)` because the audio unit hasn't propagated the device switch yet. Passing `nil` lets AVAudioEngine pull the actual current format. Caching the format produces `Failed to create tap due to format mismatch`.
- **`@ObservationIgnored` on heavy storage**: WhisperKit's `pipe`, MLX's `ModelContainer`, FluidAudio's `AsrModels` / `AsrManager`. These are not meaningfully observable values and tracking them adds churn.
- **`@preconcurrency import WhisperKit` / `@preconcurrency import AVFoundation` / `@preconcurrency import FluidAudio`**: their public APIs aren't Sendable-annotated yet. Don't remove without re-verifying nothing trips strict-concurrency diagnostics.

## Dependency pinning

`mlx-swift-examples` is pinned to commit `eb76c5b7f0cc335103bbabb0c3e1c37f8ff5d482` because later commits require `swift-transformers ≥1.3` and WhisperKit 0.18 caps it at `<1.2`. Bumping either is a multi-package coordination job.

FluidAudio (`from: 0.14.5`) shares no transitive deps with the MLX/WhisperKit side, so it's free to move.

## Persistence

- Settings: `UserDefaults` key `DictatorSettings.v2`. The decoder is field-level backwards-compatible — every property has a default, missing keys fall through.
- Dictation history: JSON file at `~/Library/Application Support/Dictator/history.json`. Capped at 500 records / 7 days.
- Conversation history (Assistant Mode multi-turn): JSON at `~/Library/Application Support/Dictator/conversations.json`.
- Audio device priority: JSON at `~/Library/Application Support/Dictator/input-devices.json`.

## What's in scratch/

`scratch/` is gitignored. Currently holds `parakeet-v3-spike/` — a self-contained SwiftPM project used to validate FluidAudio's API before integrating. Keep new spikes here; they don't ship.
