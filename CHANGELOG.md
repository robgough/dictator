# Changelog

User-facing changes to Dictator. Internal changes — refactors, build/CI tweaks,
website updates, dependency bumps that don't change behaviour — don't belong
here. Style: a single sentence the user could read without context.

At release time the workflow extracts the `## Unreleased` section, uses it as
the GitHub Release body and the Sparkle "What's new" panel inside the app, then
moves it under a `## v<version> — <date>` heading.

Inline markdown (bold, links, code) is not supported by the converter — keep
entries as plain bullet lines.

## Unreleased

_No changes yet._

## v2026.5.9 — 2026-05-21

- Dictation modes. Two ship by default — Quick (no LLM polish, fastest path) and Write (all three LLM passes). Hold the dictation hotkey and tap Tab to cycle mid-recording; the HUD shows the active mode and what's next. Pick a default from the menu bar. Add custom modes in Settings → Modes — each gets its own pass toggles, prompt addenda, and an "Auto-activate for apps" list so the right mode kicks in when you start dictating into Mail, Slack, or a code editor.
- Dictionary rows have a mic button. Tap it, say a word, Dictator fills the "Heard" field with what Whisper or Parakeet actually produced — handy when you know how a word should be spelled but not the misspelling Dictator hears.
- A bigger set of spoken-punctuation cues. New single-word: "hyphen" (-), "em dash" (—), "en dash" (–), "tilde" (~), "asterisk" (*), "ampersand" (&), "underscore" (_), "backtick" (`), "caret" (^), "ellipsis" (…), "backslash" (\). New multi-word: "at sign" (@), "hash sign" / "pound sign" (#), "dollar sign" ($), "forward slash" (/), "open bracket" / "close bracket" ([]), "open brace" / "close brace" ({}).
- Numbers in speech now turn into digits in three useful situations: arithmetic ("5 plus 3" → "5 + 3", "five percent" → "5%", "twenty-five plus three" → "25 + 3", "5 plus 6 equals 2" → "5 + 6 = 2"; same for "minus", "times", "divided by", "equals", "slash", "pipe"); composite word-form numbers anywhere ("twenty thousand and sixty two" → "20062", "one hundred and three percent" → "103%" — the "and" is optional); and runs of single-digit words ("four four seven seven seven five five five one two three four" → "7775551234", handy for phone and card numbers). "Plus N" / "minus N" with no number on its left becomes "+N" / "-N", so "plus forty-four seven seven seven…" → "+44 7775551234". Small lone numbers ("five apples", "twenty pages") stay as words.
- Your data lives in JSON files now, not in UserDefaults. Modes, prompts, hotkeys, vocabulary, recent dictations, and assistant threads sit in `~/Documents/Dictator/`; model picks and onboarding state stay per-Mac in `~/Library/Application Support/Dictator/local-settings.json`. If your Documents folder syncs (iCloud Drive, Dropbox, etc.) the shared bits follow you between Macs. Settings → General → Synced folder retargets the synced location. Existing settings migrate automatically.
- `dictator://settings` and `dictator://onboarding` URL schemes — deep-link Settings or the first-run wizard from scripts, Raycast / Alfred, or anywhere else.
- New "Tidy and tighten" grammar pass (Settings → Modes → Pass 2). Removes filler words, false starts, and self-corrections so the output reads more like writing than speech. The original "Tidy grammar" stays as the conservative option. New installs default to Tidy and tighten on the Write mode; existing users keep their previous setting.
- Short messages (six words or fewer with no internal sentence break) skip auto-capitalisation and the trailing period — natural for chat replies, mid-document edits, IDE input. "Hey." becomes "hey", "thanks for the heads up." becomes "thanks for the heads up". The pronoun "I" and its contractions ("I'm", "I'll", etc.) keep their capital. Longer messages and anything with mid-text "?", "!", or "." stay formally formatted.
- Saying "question mark", "exclamation mark", or "full stop" no longer leaves a stray period or comma in the output.
- HUD input-level meter is taller and more responsive — AirPods and lower-gain USB inputs now show useful motion instead of pinning to the floor.

## v2026.5.8 — 2026-05-19

- Dictator now requires macOS 26 or later. Macs on earlier macOS versions will stay on their currently installed version and won't be offered this update.
- Added the Apple Foundation Model as a new LLM engine option, alongside MLX and None. It runs Apple Intelligence's on-device model — zero disk space, no in-process weights, shared across every app that uses the framework. New installs that have Apple Intelligence enabled get it as the default. Existing users keep their current engine (MLX or None) and can switch from Settings → Models → Formatting.
- Settings → Models → Formatting now has an Engine picker at the top — Apple Foundation, MLX, or None. The model list and download cards only appear when MLX is selected; Apple Foundation shows a live availability status with a shortcut to System Settings if Apple Intelligence is off.
- Spoken punctuation, line breaks, and emoji names are now substituted deterministically before any LLM pass — say "comma", "new paragraph", "question mark", "fire emoji", "thumbs up emoji", and so on, and you'll get the symbol rather than the spoken word. Works with every engine (including No LLM) and across all ~3700 standard emojis via their Unicode names plus a curated list of common synonyms ("heart" → ❤️, "tada" → 🎉, etc.). Adjacent emojis no longer get commas inserted between them by the LLM ("fire emoji celebration emoji" → "🔥 🎉" rather than "🔥, 🎉"). Toggle in Settings → General → Behaviour.
- Fixed Settings description text wrapping at half the column width on some machines, leaving a large empty gap on the right.

## v2026.5.6 — 2026-05-19

- Added a "Learn Word in Dictator…" entry to the macOS Services menu — select a word in any app, right-click → Services, and a popup lets you add or update a custom-dictionary rule without opening Settings. The same action is also available from Spotlight and Shortcuts under "Learn Word in Dictator".
- Redesigned the Dictionary pane to handle large dictionaries: search field, alphabetical / as-entered sorting, compact single-line rows with hover-to-delete, and a help button that explains the per-rule options.
- Trimmed the menu-bar Recent list from 10 entries to 5 so the popup stays compact.
- Stopped the HUD's colours from drifting as the panel floats over different apps.
- Onboarding's primary buttons no longer look disabled when macOS is set to the Graphite accent.
- Formatting-LLM downloads now show smooth progress and finish as soon as the files land, instead of jumping to 100% and freezing there while the model loaded silently into RAM.
- Model downloads now show "Fetching metadata…" for the brief Hub-lookup window before the progress bar starts filling, so a slow first response doesn't look like a stalled download.
- Fixed the HUD sometimes failing to appear when a full-screen app is active, especially on a multi-monitor setup — the HUD now anchors to the screen containing the mouse cursor instead of relying on the foreground app's key-window screen.
- Softened the start/stop/done sounds — lower pitch, smoother onset, and less harmonic edge so they feel gentler.
- Added a quieter "arming" tone the moment a dictation or assistant hotkey is pressed, ahead of the regular start tone that fires when the mic is actually capturing. On built-in mics the two play almost together; on Bluetooth headsets that take a moment to negotiate, you now hear "preparing… (pause)… go" instead of wondering whether your first words made it.
- "Connecting microphone" no longer hangs forever when the mic fails to respond. If macOS doesn't bring the chosen input up within ~10 seconds (usually because another app is exclusively holding the device, e.g. a Yeti claimed by a video-call tab), Dictator now falls back to the system default automatically, and surfaces a clear error if that also fails — instead of leaving the HUD spinning indefinitely.
- Added "System default" as a first-class entry in the input priority list, draggable like any other device. Rank it where you want: at the top to always follow whatever macOS is set to, lower down to act as a fallback when your usual mics aren't connected. Existing users keep the previous behaviour — the entry is inserted at the bottom on first launch.
- Replaced the always-on Input level meter in Settings → Input with a "Test microphone" button. Click to start, click again to stop, and Dictator shows you exactly what the active transcription engine heard. More useful than a moving bar, and Settings no longer keeps an audio engine alive in the background — which was the source of occasional hangs the first time you triggered dictation after opening Settings on single-client mics like the Yeti.
- Made microphone capture much more resilient to system audio churn. Switching output devices, plugging in headphones, or another app starting playback while you were dictating could previously knock the input into a stale-format state and leave the next recording silent or stuck. The capture path now uses AVFoundation's media-capture stack (the same one Zoom and Loom use) instead of the audio-graph one, with dedicated handlers for runtime errors and device disconnects — so recordings now also abort cleanly with a useful message if your mic vanishes mid-dictation, rather than failing silently.
- Massively reduced Dictator's memory footprint after extended use. MLX's GPU buffer pool was uncapped and held onto every intermediate tensor across every LLM pass, so the process could drift into the tens of GB over a session even with no open conversations. The pool is now capped at 512 MB and flushed at the end of every LLM pass, so idle Dictator stays at model-weights-only rather than slowly creeping upward.
- Fixed the memory readout in Settings → Models → Stats. It was reading the legacy "resident set" metric which misses both compressed pages and the GPU-mapped memory MLX uses for model weights, so it was reporting hundreds of MB when Activity Monitor reported tens of GB. The in-app number now matches what Activity Monitor shows.
- Added a new "MLX (LLM)" row to Stats showing active / cached / peak GPU buffer use, so you can see at a glance how much of Dictator's footprint is the LLM's working set vs the model itself.

