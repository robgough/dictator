# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Dictator is a menu-bar macOS dictation app. Hold a hotkey → record → transcribe locally (WhisperKit or Parakeet/FluidAudio) → optionally pipe through 1–3 MLX-Swift LLM passes (format, grammar, restructure) → paste into the focused app via synthetic ⌘V. Apple Silicon only, macOS 26+, all inference on-device.

A second mode (Assistant Mode, separate hotkey) grabs the current selection, takes a spoken instruction, and either replaces the selection in-place or copies a drafted reply to the clipboard.

**Dictator Meetings** is a second, separate macOS app in this same repo (`Sources/DictatorMeetings/`) that records calls, transcribes/diarizes them locally, and writes Markdown meeting notes. It used to be a feature inside Dictator; it now ships, versions, and releases independently — see "Two apps, shared code" and "Dictator Meetings" below.

## Build & run

```bash
brew install xcodegen
cp .env.example .env && $EDITOR .env   # add DICTATOR_TEAM_ID
./gen                                  # regenerate Dictator.xcodeproj
open Dictator.xcodeproj                # then ⌘R
```

`./gen` sources `.env` before invoking `xcodegen`. `xcodegen generate` works too, but only if the env vars are already exported. `Dictator.xcodeproj` is gitignored — it's a generated artifact from `project.yml`, and it now has two application targets/schemes: `Dictator` and `DictatorMeetings`.

**CLI builds** (useful for headless verification): set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the system has `xcode-select` pointed at CommandLineTools by default, which lacks `xcodebuild`), then `xcodebuild -project Dictator.xcodeproj -scheme Dictator -configuration Debug -derivedDataPath .derivedData build` (swap `-scheme DictatorMeetings` to build the notes app instead). A post-build phase installs the signed `.app` to `~/Applications/Dictator.app` (or `~/Applications/Dictator Meetings.app`).

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

## Release notes (CHANGELOG.md / CHANGELOG-iOS.md / CHANGELOG-Meetings.md)

When a commit changes user-visible behaviour, add a one-line bullet under `## Unreleased` in the relevant changelog in the same commit:

- **Dictator (macOS dictation app) changes** → `CHANGELOG.md`
- **Dictator Meetings changes** → `CHANGELOG-Meetings.md`
- **iOS app + keyboard extension changes** → `CHANGELOG-iOS.md`
- **Shared code that ships to more than one target** → every changelog for a target it ships to (worth a brief mention even if the wording's identical): `Sources/DictatorCore/` ships to `Dictator`, `DictatorMeetings`, and `DictatorIOS`; `Sources/DictatorMac/` ships to `Dictator` and `DictatorMeetings` only (not iOS), so a change there needs both `CHANGELOG.md` and `CHANGELOG-Meetings.md`.

User-visible means something a user could notice in the app: bug fixes, new features, performance changes they'd feel, UI changes, new/changed settings. Internal changes — refactors, build/CI tweaks, website edits under `docs/`, dependency bumps with no behaviour change — don't belong here.

Style is user-language, not commit-language: "Settings no longer freezes when AirPods are connected" rather than "Move InputLevelMonitor engine startup off the main thread". Inline markdown (bold, code, links) isn't supported by the HTML converter — keep entries plain text.

At release time the workflow extracts the relevant section via `.github/scripts/release_notes.py` (it takes the changelog path as an optional argument; defaults to `CHANGELOG.md`), uses it as the GitHub Release body *and* as the Sparkle "What's new" panel description (inlined in the appcast's `<description>` CDATA), and moves it under a `## v<version> — <date>` heading. Dictator releases off `v*` tags into `docs/appcast.xml`; Dictator Meetings releases off `meetings-v*` tags into `docs/appcast-meetings.xml` — see `.github/workflows/release.yml`'s `release` and `release-meetings` jobs.

If `## Unreleased` is empty at tag time the workflow warns but doesn't fail — some releases legitimately have no user-facing changes (e.g. signing-only fixes), in which case the release notes render "No user-facing changes in this release."

## Architecture

Everything runs on the main actor unless explicitly hopped off it. Concurrency is `SWIFT_STRICT_CONCURRENCY=minimal` but Swift 6 still enforces actor isolation on closures — see "Swift 6 gotchas" below.

### Two apps, shared code

Four source folders, three build targets:

- **`Sources/Dictator/`** — the menu-bar dictation app (`Dictator` target/scheme). Pipeline, HUD, hotkeys, dictation modes/styles, vocabulary, history, the LLM socket *server* (`LLM/LocalLLMServer.swift`).
- **`Sources/DictatorMeetings/`** — the standalone meeting-notes app (`DictatorMeetings` target/scheme). Windowed, has a Dock icon (not an `LSUIElement` accessory like Dictator), its own Settings window, its own settings/persistence, provider abstraction, and coach island.
- **`Sources/DictatorMac/`** — code shared between the two *macOS* targets only (audio capture, model catalog/manager, MLX/Apple-Foundation LLM engines, `LLMWire`/`LLMScheduler`, shared UI primitives). Compiled into both targets' `sources` list in `project.yml` — **not** a framework: no `public` churn, no module boundary, and each process gets its own copy of every `@MainActor enum …Holder { static let shared }` singleton, which is what we want (Dictator and Dictator Meetings are separate processes with separate memory).
- **`Sources/DictatorCore/`** — code shared across *all three* app targets, macOS and iOS alike (`Dictator`, `DictatorMeetings`, `DictatorIOS`). Same non-framework, own-copy-per-process approach as `DictatorMac`.

The two Mac apps are separate processes with separate bundle IDs (`net.robgough.Dictator`, `net.robgough.DictatorMeetings`), separate Settings, and separate release channels (`v*` vs `meetings-v*` tags — see "Release notes" above and "Dictator Meetings" below) — the only thing they actually share at runtime is the LLM socket.

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

Two capture stacks coexist in the codebase, chosen per use case (a third, meeting-specific stack lives under "Dictator Meetings" below):

- **`Sources/DictatorMac/Audio/AudioRecorder.swift` (dictation, shared by both Mac targets) uses `AVCaptureSession`.** Capture-only workloads sit awkwardly inside `AVAudioEngine`'s audio-graph model — every recording paid for the graph machinery (AUHAL device-property overrides, tap format propagation, ConfigurationChange rebuilds) without using it, and that machinery was the source of most flakiness on USB devices that share clock with the output (Yeti, audio interfaces) where engine ConfigurationChange didn't always fire for subtle clock shifts. `AVCaptureSession` is the AVFoundation media-capture stack with explicit beginConfiguration/commitConfiguration hot-swaps, dedicated runtime-error / device-disconnect notifications, and a delegate-queue stream of `CMSampleBuffer`s.
- **`Sources/DictatorIOS/IOSAudioRecorder.swift` (iOS dictation) uses `AVAudioEngine`.** Same shape as the meeting mic recorder (see below), minus the voice processing.

Preferred input device for both stacks comes from `AudioDeviceManager` (`Sources/DictatorMac/Audio/`), which keeps an ordered list per machine; if the override doesn't take the recorder falls back to the system default. `AudioDeviceEnumerator` extends that with output-side transport-type probes (`kAudioDevicePropertyTransportType`) so Dictator Meetings' AEC `.auto` mode can distinguish headphones (skip AEC) from built-in speakers (enable AEC).

### Text injection

`Injection/TextInjector.swift` uses `NSPasteboard` + synthetic ⌘V via `CGEvent`. The pre-paste selection range is captured via `AXUIElement` so Assistant Mode's REPLACE flow can re-select what it just pasted (lets the user re-prompt the assistant on the inserted text).

Falls back to clipboard-only if Accessibility isn't granted; the HUD surfaces the reason. `focusedElementIsEditableText()` gates REPLACE-mode pastes so we don't dump assistant output into a URL bar or somewhere it wasn't meant to go.

### Service holders pattern

`Services/ServiceHolders.swift` exposes shared singletons (`TranscriptionServiceHolder`, `ParakeetServiceHolder`, `LLMServiceHolder`) as `@MainActor enum` with a single `static let shared`. Pipeline and Settings both reach for the same instance — model loads are amortised across UI and dictation paths.

## Dictator Meetings

The standalone meeting-notes app (`Sources/DictatorMeetings/`). Everything below is specific to it; it does not apply to the dictation app.

### Meeting mic capture

**`MeetingMicRecorder.swift` uses `AVAudioEngine`**, unlike Dictator's `AVCaptureSession`-based recorder (see "Audio capture" above). Meetings need `setVoiceProcessingEnabled(true)` for echo cancellation against the speakers, which `AVCaptureSession` doesn't expose — only the `AVAudioEngine.inputNode` path does. Rebuilds the engine on `AVAudioEngineConfigurationChange` and continues writing to the same CAF when the post-swap native rate matches; drops post-swap buffers when rates diverge so the on-disk file stays decodable instead of getting silently corrupted. (See the `meeting_mic_yeti_vpio_broken` note in auto-memory before touching this — real-time AEC via VPIO was tried and reverted; bleed is instead handled by a post-pass dedup.)

### The LLM socket — Dictator lends Meetings its loaded model

Dictator shares its already-loaded LLM with Dictator Meetings over a Unix domain socket, so the two apps don't both hold a model resident when Dictator is already running one. Dictation always wins: an in-flight meeting generation is preempted at the next token the moment a dictation starts.

- **Socket**: `~/Library/Application Support/Dictator/llm.sock` (`LLMSocket.path` in `Sources/DictatorMac/LLM/LLMWire.swift`), directory mode 0700, socket file mode 0600. Newline-delimited JSON, one connection per request, UTF-8. `LLMWireRequest`/`LLMWireResponse` are the wire types (shared, in `DictatorMac`); `.status` and `.complete` are the two ops. v1 sends a single `.done` per request (no streaming yet, though the `.chunk` response kind is reserved for it).
- **Server**: `Sources/Dictator/LLM/LocalLLMServer.swift`, an `NWListener` Dictator starts from `AppState.bootstrap()` (after model preload kicks off, so it can't block launch) and restarts when `settings.shareLoadedModelEnabled` flips on. Refuses `.complete` (`unavailable`) when sharing is off, the engine is `.none`, or the model isn't currently loaded — it never loads a model just to answer a remote request; falling back is the caller's job.
- **Scheduler**: `Sources/DictatorMac/LLM/LLMScheduler.swift`, `@MainActor final class LLMScheduler` with two priorities. `.background` work (socket requests from Meetings) runs in its own cancellable `Task`; `.interactive` work (Dictator's own pipeline/assistant calls) cancels any running background job first, then runs directly — `ModelContainer.perform` serialises, so the interactive call just gets the container as soon as the cancelled generation returns. A cancelled background job surfaces to its caller as `preempted`; a second concurrent background request gets `busy`.
- **Client**: Dictator Meetings' `DictatorSocketProvider` (see "Provider abstraction" below) checks the socket file exists and Dictator is actually running (`NSRunningApplication.runningApplications(withBundleIdentifier: "net.robgough.Dictator")`) before trying it, and retries `preempted`/`busy` responses a bounded number of times before giving up and falling back to its own local provider.

### Provider abstraction

Dictator Meetings writes notes through a `MeetingLLM` provider, not a single hardcoded engine — two independent slots, **live notes** and **final notes**, each pointing at its own `ProviderConfig`. Kinds: `dictator` (the socket above), `localMLX` (its own in-process MLX model, sharing `DictatorMac`'s engine code), `apple` (Apple Foundation Models), `openAICompatible` (presets: OpenAI, OpenRouter, or a custom base URL), `anthropic`. `ProviderRegistry` resolves a slot to a live instance and falls back automatically — Dictator socket unavailable → local MLX (if downloaded) → Apple (if usable) → nil, with a `requirementMessage` explaining what to configure when nothing resolves.

**Keys live in the Keychain only, never in synced settings.** A cloud provider's API key is stored via `KeychainStore` under service `net.robgough.DictatorMeetings`, account = the provider's id — not in `meetings-settings.json` or any other file that syncs via iCloud Drive / Dropbox / etc. (`keychainSyncEnabled` opts a user into `kSecAttrSynchronizable`, i.e. iCloud Keychain, but that's still Apple's keychain sync, not Dictator's own settings sync.) Never add a provider key, token, or secret to `MeetingsSettings` or any other `Codable` settings struct that gets written to a JSON file — that's the one rule in this whole abstraction that isn't negotiable.

## Swift 6 gotchas baked into the code

These are non-obvious and load-bearing — don't "clean up" without understanding why:

- **`@Sendable` on audio-thread closures**: `AVAudioEngine.installTap` invokes its block on the realtime audio queue. Without `@Sendable`, Swift 6 inherits `@MainActor` isolation from the enclosing method and dispatch traps the moment the audio thread fires the closure. See `MeetingMicRecorder.configureAndStartEngine` and `IOSAudioRecorder` — both the live AVAudioEngine consumers in this repo. (`AudioRecorder` is `AVCaptureSession`-based and uses its own `@Sendable` `SampleBufferForwarder` shim for the same reason: the delegate callback hits an off-main queue.)
- **`format: nil` in `installTap`**: `outputFormat(forBus:)` returns a stale format right after `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice, ...)` because the audio unit hasn't propagated the device switch yet. Passing `nil` lets AVAudioEngine pull the actual current format. Caching the format produces `Failed to create tap due to format mismatch`. Same applies to `MeetingMicRecorder` after the voice-processing toggle + device override.
- **`@ObservationIgnored` on heavy storage**: WhisperKit's `pipe`, MLX's `ModelContainer`, FluidAudio's `AsrModels` / `AsrManager`. These are not meaningfully observable values and tracking them adds churn.
- **`@preconcurrency import WhisperKit` / `@preconcurrency import AVFoundation` / `@preconcurrency import FluidAudio`**: their public APIs aren't Sendable-annotated yet. Don't remove without re-verifying nothing trips strict-concurrency diagnostics.

## Dependencies (June 2026)

The historical swift-transformers diamond (WhisperKit 0.18 capped it `<1.2`, newer MLX needed `≥1.3`, so `mlx-swift-examples` was pinned to a 2025 commit) is resolved — all three sides moved:

- **WhisperKit** comes from `argmaxinc/argmax-oss-swift` (the v1.0 rebrand; same `WhisperKit` product). It vendors Hub/Tokenizers into ArgmaxCore and no longer constrains swift-transformers.
- **`mlx-swift-lm` 3.x** replaced `mlx-swift-examples`. 3.x is decoupled from swift-transformers: model loading takes `Downloader`/`TokenizerLoader` protocols. We deliberately *don't* use its `MLXHuggingFace` macro glue — `LLM/HubBridge.swift` hand-implements both protocols against the legacy `HubApi(downloadBase:)` so LLM weights keep the on-disk layout `<llmRoot>/models/<org>/<name>/` that ModelManager's download/resume/delete logic (and every existing install) depends on. The macro path would switch to HubClient's `models--org--name/snapshots/` cache layout — don't "simplify" to it without a disk-migration story.
- **swift-transformers** is now a direct dependency (Hub + Tokenizers products) feeding those bridges.

FluidAudio (`from: 0.14.5`) shares no transitive deps with the MLX/WhisperKit side, so it's free to move.

## Persistence

- Settings: `UserDefaults` key `DictatorSettings.v2`. The decoder is field-level backwards-compatible — every property has a default, missing keys fall through.
- Dictation history: JSON file at `~/Library/Application Support/Dictator/history.json`. Capped at 500 records / 7 days.
- Conversation history (Assistant Mode multi-turn): JSON at `~/Library/Application Support/Dictator/conversations.json`.
- Audio device priority: JSON at `~/Library/Application Support/Dictator/input-devices.json`.
- Dictator Meetings settings: same synced/local split as Dictator's own settings — synced envelope in `SyncedStorage.directory/meetings-settings.json`, per-Mac bits (retention days, model picks, onboarding state, the local-provider model ID) in `~/Library/Application Support/Dictator/meetings-local-settings.json`. On first launch (neither file exists) it one-time-imports the matching keys out of Dictator's own settings files. Meeting recordings/notes/transcripts and people data keep their existing paths (`<synced>/Meetings/`, `~/Library/Application Support/Dictator/Meetings/`) unchanged by the app split.
- Dictator Meetings provider API keys: macOS Keychain only (see "Provider abstraction" above) — never in the settings JSON files above, synced or local.

## What's in scratch/

`scratch/` is gitignored. Currently holds `parakeet-v3-spike/` — a self-contained SwiftPM project used to validate FluidAudio's API before integrating. Keep new spikes here; they don't ship.
