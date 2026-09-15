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

Pin local builds to the **Developer ID Application** cert (the one releases are signed with), not the Apple Development cert. TCC keys a grant to the app's code-signing requirement, which includes the certificate's name; a local build signed differently from the Sparkle-installed release looks granted in System Settings but fails `AXIsProcessTrusted()` and prompts on every paste. With the release cert, grants survive switching between local and released builds. If a grant does go stale: `tccutil reset Accessibility net.robgough.Dictator` (and `ScreenCapture`), relaunch, grant once.

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
.fixingGrammar? → .restructuring? → .translating? → .assisting? → .compacting? → .done → .idle
                                                                                      ↘ .failed
```

`.capturingSelection`, `.assisting`, `.compacting` only fire in Assistant Mode. `.fixingGrammar` and `.restructuring` are optional dictation passes gated by settings + word count. `.translating` fires only when a mode's output language differs from its spoken one.

**Three** entry points, all on the same `Pipeline` instance so the HUD panel and menu bar render every path off the same observed state:

- `startRecording` / `finishRecording` — dictation, pastes into the focused app.
- `startAssistant` / `finishAssistant` — Assistant Mode.
- `startJournal` / `finishJournal` — journal dictation. Identical capture and passes to a normal dictation (it just sets `inFlight.isJournal`); the only difference is at delivery, where `finish` appends to the user's journal file via `JournalWriter` and skips every insertion-point behaviour (context join, trailing space, Return) because there is no insertion point. Mode selection ignores app/website bindings — a journal entry isn't going into the app in front, so that app has no business choosing how it's written.

`commitRecording()` is the HUD's click-to-stop: it routes to whichever `finish…` owns the in-flight capture.

Mode resolution at recording start is most-specific-first: **website** binding (`urlPatterns`, matched against the frontmost browser's URL via `BrowserURLReader`) beats **app** binding (`appBundleIDs`) beats `defaultModeID`. The URL read walks a browser's AX tree, so it's skipped entirely unless `settings.anyModeHasURLBinding` — this is the hotkey-press path, which has a documented history of main-thread stalls.

### Chat, tools, and MCP

`Sources/Dictator/Chat/` + `Sources/Dictator/UI/Chat/` + `Sources/DictatorMac/MCP/`.

Dictator's chat window is an agent harness over whichever MLX model is already
loaded. Clicking the app in the Dock opens it (`applicationShouldHandleReopen`);
so does the menu bar's Chat item and `dictator://chat`.

- **One round, not a loop, at the engine.** `LLMChatStreaming.streamChatRound`
  (implemented by `MLXLLMService`, opt-in like `LLMUsageReporting` so the Apple
  engine can't be handed a loop it can't run) does prompt → prose and/or tool
  calls. The *loop* — tool dispatch, approval, round cap, persistence — is
  `ChatEngine`, because all of that is app policy.
- **Raw message dicts, not `Chat.Message`.** `ChatWireMessage` renders
  `[String: any Sendable]` straight into the chat template. This is not a style
  choice: `Chat.Message` can't carry `tool_calls`, and Gemma 4's template emits a
  tool result *only* by scanning forward from an assistant message that has
  them — without it the model never sees the result and calls the same tool
  forever. Measured; see the `chat_tool_calling_findings` note.
- **Chat runs at `LLMScheduler.background`, so dictation always wins.** Each
  round re-renders the whole thread, which costs a prefill but makes a round
  *idempotent* — a preempted round is simply re-run. `ChatEngine` waits for
  `Pipeline.state == .idle` before retrying, because MLX only checks
  cancellation inside the token loop: re-entering mid-dictation starts an
  uncancellable prefill that the next pass then queues behind. (This is why
  `ChatSession`, which keeps a KV cache, was not used — a cancelled generation
  leaves the cache holding half a turn.)
- **Replies are rendered as blocks, not one string.** `ChatMarkdown.parse`
  splits fenced code from prose before anything is displayed;
  `AttributedString(markdown:)` does inline markdown only, so a fenced block
  arrived with its backticks intact and its newlines folded away — a script
  written line by line became one line. `CodeHighlighter` is a deliberately
  shallow tokeniser (comments, strings, numbers, per-language keywords) that
  returns ranges, so it stays testable without SwiftUI.
- **One store, two ways in.** Assistant Mode and the chat window are the same
  conversation reached by different doors, and both persist as `ChatThread` in
  `ChatStore` (`origin` says which, and the sidebar shows it). What stays
  separate is the *call path*: `assist()` is one shot at
  `LLMScheduler.interactive` with a person holding a hotkey waiting for text to
  land at their cursor, while `ChatEngine` is up to eight rounds of tool
  dispatch at `.background`. Merging those would put a tool loop in front of a
  paste, which is the one thing Assistant Mode must never do.
  `ChatThread.assistantTurns` derives the `[ConversationTurn]` that `assist()`
  takes — the same storage-vs-payload split `ChatWireMessage` makes, and what
  let this land without touching either engine. Tool messages are skipped in
  that derivation (they can't be expressed as a turn), so a promoted thread
  keeps working through the hotkey. `scratch/chat-merge-check` round-trips the
  real archive field by field.
- **Replies can be inserted back where you were** (`ChatInsertion`). The hotkey
  can paste at your cursor because the target app is still in front; the chat
  window can't, so the target is *remembered* from
  `didActivateApplicationNotification` (plus a `rememberFrontmost()` just before
  the window takes focus, for the app that was there at launch), then activated
  and polled until it's genuinely frontmost before ⌘V — `activate()` is a
  request, not a fact, and pasting too early lands the text back in the chat
  window. Text goes on the clipboard *first*, so every failure path still leaves
  the user one ⌘V from what they asked for.
- **Attachments land in the chat's folder and are read once** (`ChatAttachment`,
  `ChatAttachments`). A file the user drags in is *copied* into the working
  directory, so the ordinary file tools can reach it afterwards — an attachment
  the model can only see in the prompt is one it can't be asked to edit.
  Extraction happens at attach time and is **stored on the attachment**: a round
  re-renders the whole thread, so deriving it at render time would re-parse a
  PDF and re-run a vision pass on every round of every turn. Text is sniffed
  (UTF-8, no NUL) rather than trusted by extension, because `.env`, `.log` and
  extensionless files are all text; PDFs go through PDFKit; images reuse
  `readImage`, the same vision-to-prose path as `read_screen`. Anything that
  yields no text carries a `note` saying why, inlined for the model and shown on
  the chip — a scanned PDF arriving as an empty string is the failure that
  produces a confident answer about a document nobody read.
  `scratch/attachment-check` covers classification, both extractors and the
  no-clobber naming.
- **Each chat owns a folder** — `<synced>/Chat Files/<slug>-<id6>/` (`ChatFiles`).
  The name is fixed on first use and stored on the thread, never derived live:
  titles change, and a renamed folder would invalidate every path already
  written into the transcript. Deleting a chat offers to delete its files and
  says where they are; "delete all chats" never touches files. The card's export is a
  **copy**, not a move: the chat folder is a *working* directory, and the
  assistant may be asked to change the file again — it can only do that to a
  file it still has. What the user takes out is a point-in-time snapshot, and
  going stale is what a snapshot is for. (This was built as a move first and
  was wrong: it left the chat unable to edit its own work.)
- **The chat can edit its own files**: `list_files`, `read_file`, `update_file`
  alongside `create_file`. `update_file` is separate rather than an
  `overwrite: true` flag, because overwriting is the one destructive operation
  here and a flag gets set by accident.
- **A chat works in its own folder.** `ChatThread.workingDirectoryPath` and
  `ChatFiles.workingDirectory` can point one at a folder the user chose, and the
  containment below already supports it, but **no UI sets it** — that's parked
  until it can be a deliberate mode. `ChatFiles.ownsFolder` is the line that
  matters when it comes back: deletion, and the delete confirmation's file
  count, apply only to folders Dictator created.
- **`ChatFileWriter.resolve` is the containment boundary**, and it is the thing
  to be careful with. Subpaths are allowed (`src/main.swift`), but absolute
  paths, `~`, any `..` component and hidden components are refused rather than
  normalised, and the resolved parent is compared against the resolved root
  **with symlinks followed** — a symlink inside the folder is otherwise a door
  out of it. `scratch/tools-check/ContainmentCheck.swift` attacks it, including
  that symlink case.
- **`create_file` writes only inside the working directory.** The model picks the
  filename, so it must not pick the *path*; anything containing a separator is
  refused rather than repaired, the extension is allow-listed to
  non-executable document types, and a clashing name gets a numbered sibling —
  it never overwrites. The write returns a structured `Outcome`, not a
  sentence, because the transcript renders the file itself (`ChatFileCard`:
  preview, copy, open, reveal, save-a-copy) — one folder is Dictator's answer
  to "where do files go", and the card is where the user overrides it. The card
  re-reads from disk on each render rather than caching contents with the
  message, so a file the user has since edited doesn't display stale text.
- **Two tools reach outside the machine.** `fetch_url` (`WebFetcher`) opens a
  public page: https/http only, loopback/link-local/private ranges refused
  before *and* after redirects, size and character caps, and the page text is
  returned explicitly fenced as untrusted quoted material — anyone can put
  "ignore your instructions" on a web page. `run_shortcut` (`ShortcutsBridge`)
  runs the user's own Shortcuts via `/usr/bin/shortcuts`; it needs no
  entitlement because the shortcut asks for whatever *it* needs when it runs.
  It is the **only built-in that requires approval** — everything else reads the
  user's own data, whereas a shortcut can do anything they have ever automated.
  Both are covered by `scratch/tools-check`, which symlinks the shipping source.
- **Above ~24 tools the schemas are deferred.** Every tool's JSON schema is
  re-sent on *every round* (there's no prompt cache), so one 69-tool MCP server
  costs ~17K tokens per round — half of Gemma 4 12B's window before the user
  types. `ChatToolset` then advertises only the built-ins plus `find_tools`,
  and puts a name+description **index** of the rest in the system prompt.
  The index is load-bearing: `find_tools` *alone* made both Qwen models fail
  half the scenarios, because a model shown one meta-tool doesn't know anything
  else exists. With the index it's 3× faster than sending everything and just
  as accurate (9B, chained question: 15.2s → 4.8s). Dispatch resolves against
  the whole catalogue, never the advertised subset.
- **The clock goes *after* the newest user message, and says what it's for.**
  It's on the message rather than in the system prompt because the prompt's head
  has to stay byte-stable for the cache — but prefixing it made the timestamp
  the nearest antecedent for any pronoun, and "give me that as a JSON object"
  after a list of cities returned `{day, date, time, timezone}`. Position alone
  isn't enough: a small model shown an unexplained fact treats it as the
  subject. `scratch/clock-anaphora-check` measures all three framings over 5
  models — prefixed 3/15 pronoun scenarios, suffixed 11/15, suffixed **and
  labelled** 15/15, with clock questions 15/15 throughout. Removing the clock
  also fixes pronouns and is not an option: every model then states a
  confidently wrong date rather than admitting it doesn't know.
- **Prefill is cached across the rounds of a turn** (`ChatPromptCache`). The
  baseline holds the prompt *minus its final token* — `TokenIterator.prepare`
  consumes everything it's handed, so caching the whole prompt and then seeding
  generation with its last token processes that token twice and shifts every
  position after it. Generation runs on a throwaway copy, so a preempted round
  needs no rollback — which matters because rollback isn't available: Qwen 3.5's
  linear-attention layers use `ArraysCache`, `isTrimmable == false`, so
  `trimPromptCache` is a no-op on the models we recommend. **Exactly one copy
  per round**: two cost more than the prefill they saved (8.4s → 20.3s on a 4.4K
  prompt). Anything that makes the head of the prompt unstable defeats this —
  which is why the clock lives on the newest user message, not in the system
  prompt.
- **`chatCapable` on `LLMModel` gates the window**, set only from
  `scratch/tool-call-check`. Models without it keep today's behaviour and the
  window explains why rather than hiding.
- **MCP** is a hand-rolled stdio client (`MCPClient`, protocol `2025-06-18`), not
  `modelcontextprotocol/swift-sdk` — that SDK pulls swift-nio plus
  `swift-docc-plugin` on `branch: "main"`, and an unpinned branch in a shipping
  graph is the swift-transformers diamond all over again. Servers start lazily
  on first use, tools are namespaced `<serverNamespace>__<tool>`, every MCP tool
  asks for approval until the user says "always", **env values live in the
  keychain** (names only in `mcp-servers.json`, which is per-Mac, not synced),
  and `MCPProcessReaper` SIGTERM/SIGKILLs the subprocesses synchronously at quit
  because `applicationWillTerminate` returns straight into `exit()`.

### Two transcription engines behind one protocol

`Transcription/ASREngine.swift` is the small surface (`download`, `ensureLoaded`, `unload`, `transcribe`, `currentModelID`, `isLoading`) both `TranscriptionService` (WhisperKit) and `ParakeetService` (FluidAudio CoreML on the ANE) conform to. Pipeline holds both and dispatches via `activeASR` based on `settings.transcriptionEngine`. The protocol omits WhisperKit's `prompt:` arg deliberately — prompt biasing is parked (see `whisper_prompt_biasing.md` in auto-memory), and Parakeet has no equivalent.

Each engine's weights live under `~/Library/Application Support/Dictator/Models/{whisper,parakeet,llm}/<id>/`. `ModelStorage` is the single source of truth for these paths. FluidAudio is given an explicit `to:` URL so it doesn't fall back to its default `~/Library/Application Support/FluidAudio/Models/...` location.

### Pass validation (the "did the LLM go off the rails?" guard)

Each LLM pass has a deterministic post-check; the pipeline reverts to the previous stage's output if the check fails. This is the whole reason small local LLMs are tolerable here.

- **Pass 1 (Format)**: question-shaped input (trailing `?` or interrogative first word) skips Pass 1 entirely — Whisper already punctuates correctly and small models are biased toward *answering* questions rather than transcribing them. For everything else, `Pipeline.passOnePreservesContent` validates that ≥60% of input anchor words (≥4 chars, not punctuation triggers) survive in the output AND the word count didn't grow more than 15% + 3. Failure → fall back to raw Whisper transcript with a HUD note.
- **Pass 2 (Grammar)**: word-level Levenshtein distance. Reverts if drift exceeds `settings.grammarPassMaxEditFraction` (default 0.15).
- **Pass 3 (Structure)**: strict word-sequence equality after lowercasing/stripping non-alphanumerics. Reverts on any word change — bullets/breaks only.
- **Translate** (only when `mode.outputLanguage` differs from `mode.spokenLanguage`): runs LAST, after the style passes, so those operate on the language actually spoken. Every content-preservation gate is meaningless for a translation by definition, so it gets its own: `translationLooksSane` bounds the output/input word ratio (catches answering and summarising, the two ways this pass fails) and requires numbers to survive.

The `Vocabulary` substitution pass runs between Pass 1 and Pass 2. Three match modes per entry (`VocabularyEntry.matchMode`): `.literal` (the original case-insensitive whole-word replace), `.regex`, and `.phonetic` — Metaphone-keyed sound-alike matching via `PhoneticKey`, which is what makes one rule cover every spelling the decoder invents for a name.

`.phonetic` is the default for new rules, and `VocabularyEntry.upgradedMatchMode` migrates pre-match-mode rules to it on decode. That's only safe because **phonetic is a strict superset of literal**: it matches the exact text first, and a pattern too short to key (under `PhoneticKey.minPatternLetters`) falls back to a whole-word literal replace rather than going inert. The migration deliberately skips `caseSensitive` and `wholeWord == false` rules — phonetic can express neither, so upgrading those would silently drop behaviour the user asked for.

Read `PhoneticKey`'s doc comment before touching its gates: the obvious "also require a small edit distance" check was tried and defeats the whole feature, and the common-word stoplist is what's holding the false-positive rate down instead.

### Prompt customisation model

`Settings/DictatorSettings.swift` has a built-in prompt per pass (source of truth, not editable), an `…PromptAddendum` (appended under a labelled header — for "always use British spelling" tweaks), and an `…PromptOverride` (full replacement — escape hatch, addendum ignored). `effectiveXxxPrompt` resolves these.

The assistant prompt additionally substitutes `{{USER_NAME}}` in its few-shot examples at runtime — small models copy the *shape* of examples far more reliably than they obey abstract rules, so the user's actual name in the example signatures stops "[Your Name]" placeholders from leaking into drafted emails.

### Audio capture

Two capture stacks coexist in the codebase, chosen per use case (a third, meeting-specific stack lives under "Dictator Meetings" below):

- **`Sources/DictatorMac/Audio/AudioRecorder.swift` (dictation, shared by both Mac targets) uses `AVCaptureSession`.** Capture-only workloads sit awkwardly inside `AVAudioEngine`'s audio-graph model — every recording paid for the graph machinery (AUHAL device-property overrides, tap format propagation, ConfigurationChange rebuilds) without using it, and that machinery was the source of most flakiness on USB devices that share clock with the output (Yeti, audio interfaces) where engine ConfigurationChange didn't always fire for subtle clock shifts. `AVCaptureSession` is the AVFoundation media-capture stack with explicit beginConfiguration/commitConfiguration hot-swaps, dedicated runtime-error / device-disconnect notifications, and a delegate-queue stream of `CMSampleBuffer`s.
- **`Sources/DictatorIOS/IOSAudioRecorder.swift` (iOS dictation) uses `AVAudioEngine`.** Same shape as the meeting mic recorder (see below), minus the voice processing.

Captured audio goes through `SilenceTrimmer` (`Sources/DictatorCore/Audio/`) before transcription when `settings.trimSilenceEnabled` — leading/trailing only, never internal (a mid-dictation pause is where the sentence boundaries are). It returns the clip untouched whenever trimming would be unsafe, so it can't eat a quiet speaker.

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

**Two locations, and it matters which.** The *synced* folder is `SyncedStorage.directory` — `~/Documents/Dictator/` by default, or whatever the user picked in Settings → General → Synced folder. Per-Mac state stays in `~/Library/Application Support/Dictator/`.

Several files moved from Application Support to the synced folder and are migrated on launch by `SyncedStorage.migrateFromAppSupport`. **The Application Support copies are left behind and go stale** — reading one while debugging will show you months-old data and send you off after a bug that isn't there. Always confirm which path a store actually resolves before trusting its contents.

- Settings: synced user preferences in `<synced>/settings.json`; per-Mac bits in `~/Library/Application Support/Dictator/local-settings.json`. `UserDefaults` key `DictatorSettings.v2` is a *legacy migration source only* (`legacyUserDefaultsKey`), not where settings live. The decoder is field-level backwards-compatible — every property has a default, missing keys fall through. Adding a top-level field needs it listed in `syncedKeys`/`localKeys` in `persist()` or it silently won't survive a relaunch.
- Dictation history: `<synced>/history.json`. Capped at 500 records / 7 days.
- Vocabulary: `<synced>/vocabulary.json`. Assistant memory: `<synced>/assistant-memory.md`. Correction suggestions: `<synced>/correction-suggestions.json`.
- Usage stats: `<synced>/stats.json`, keyed per device so two Macs on iCloud Drive can't clobber each other's counters. `UsageStats` has a hand-written `Codable` plus a memberwise `+` and a `max()`-per-field merge — a new counter needs all of them or it won't persist or sum.
- Conversations: `<synced>/chats.json` — **both** the chat window's threads and Assistant Mode's, since they merged into one store. Retention is per-origin: chat threads are capped at 200 with no age cap (a chat is a document people come back to), assistant threads are swept after 14 days unless `promoted`. The old `conversations.json` is folded in on first launch and renamed `conversations.migrated.json`; `SyncedStorage.migrateFromAppSupport` still moves it into the synced folder first, so don't delete that line.
- MCP servers: `~/Library/Application Support/Dictator/mcp-servers.json` (**per-Mac** — it holds absolute binary paths). Their environment *values* are keychain-only, under service `net.robgough.Dictator`, account `mcp.<serverID>.env.<KEY>`.
- Audio device priority: `UserDefaults`, key `AudioDeviceManager.knownDevices.v1` — **not** a JSON file.
- Dictator Meetings settings: same synced/local split as Dictator's own settings — synced envelope in `SyncedStorage.directory/meetings-settings.json`, per-Mac bits (retention days, model picks, onboarding state, the local-provider model ID) in `~/Library/Application Support/Dictator/meetings-local-settings.json`. On first launch (neither file exists) it one-time-imports the matching keys out of Dictator's own settings files. Meeting recordings/notes/transcripts and people data keep their existing paths (`<synced>/Meetings/`, `~/Library/Application Support/Dictator/Meetings/`) unchanged by the app split.
- Dictator Meetings provider API keys: macOS Keychain only (see "Provider abstraction" above) — never in the settings JSON files above, synced or local.

## What's in scratch/

`scratch/` is gitignored and holds ~18 self-contained SwiftPM spikes used to validate something headlessly before it touches the app. Keep new ones here; they don't ship. The ones worth knowing about:

- `vlm-vision-check/` — loads a downloaded checkpoint through `VLMModelFactory` from the app's real on-disk layout, feeds it a screenshot, prints `phys_footprint`. **Run this before setting `visionCapable` on a catalog entry, and read the output** — a model that loads is not a model that answers usefully.
- `gemma4-upstream-check/` — takes HF repo ids, downloads via the same Hub bridge the app uses, loads and generates. The fastest way to prove a new catalog model works end to end without launching Dictator.
- `tool-call-check/` — per model: is the tool-call format inferred, does it emit a parseable call with the right arguments, and does it *stop* calling once fed a result. **Run this before setting `chatCapable`.** Takes a list of repo ids and downloads anything missing. Also runs the tool-list conditions (2 / 60 / find_tools / index + find_tools) that set `ChatToolset.deferAboveToolCount` — re-run it before changing that threshold.
- `clock-anaphora-check/` — renders the chat prompt four ways (clock prefixed,
  suffixed, suffixed-and-labelled, absent) against scenarios that need the clock
  and scenarios whose pronoun must resolve to the previous turn. Run it before
  changing how the time is injected; the shipping framing is marked `[SHIPPING]`
  and is byte-identical to `ChatEngine.withClock`.
- `attachment-check/` — classification (text sniffing, images, binaries),
  text and PDF extraction including a PDF with no selectable text, truncation,
  and `availableURL`'s no-clobber naming. Builds its PDFs rather than shipping
  fixtures. Run it before changing what an attachment hands the model.
- `chat-merge-check/` — round-trips the real `conversations.json` through the
  shipping migration (`ChatThreadMigration.swift`, symlinked) and compares every
  turn field by field, plus the compaction split and the tool-messages-skipped
  case. Run it before touching how a turn unfolds into messages: the failure
  mode there is silent data loss, not a crash.
- `mcp-client-check/` — symlinks the app's real MCP sources and runs them against a deliberately awkward Python server (non-JSON banner, pagination, a server→client request, an `isError` tool, a tool that never replies). Run it a few times: the two transport bugs it caught were both intermittent.
- `gemma4-qat-spike/` — the historical 3.31.3 + vendored-architecture reproduction, kept for context only; the vendored `Gemma4/` sources it mirrors were deleted when 3.31.4 landed native support.

A spike that pins dependency versions must match `project.yml` exactly, or you're testing a different app than the one you ship.
