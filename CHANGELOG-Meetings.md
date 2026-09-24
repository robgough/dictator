# Dictator Meetings Changelog

User-facing changes to Dictator Meetings. Internal changes — refactors,
build/CI tweaks, website edits under `docs/`, dependency bumps with no
behaviour change — don't belong here. Style: a single sentence the user
could read without context.

At release time the workflow extracts the `## Unreleased` section, uses it
as the GitHub Release body and the Sparkle "What's new" panel inside the
app, then moves it under a `## v<version> — <date>` heading.

Inline markdown (bold, links, code) is not supported by the converter —
keep entries as plain bullet lines.

## Unreleased

- API keys for cloud providers save again with "Sync keys with iCloud Keychain" switched on. That sync isn't available to this build, and every save was silently failing; keys are now kept in this Mac's Keychain, the setting says why it's unavailable, and the key field tells you it was saved.
- Choosing a model for OpenRouter, OpenAI or another compatible service no longer means typing its id: Choose… lists every model the service offers, searchable, with its context size and price.
- A companion panel floats beside the call while you record: the time and Stop, whether both sides are being heard, how the talking is split, your key points, the last few things the notes caught, and a field to jot something into your pad. Drag it wherever suits; turn it off in Settings.
- New Today screen: your next meeting from the calendar, with a button to record it the moment it starts, the meetings still waiting for notes, and the action items from all your notes, yours first. Ticking one off ticks it in that meeting's notes.
- The sidebar is now a library: All meetings, Needs notes (with a count), each kind of meeting, and the people you meet with. Choosing one lists those meetings beside the meeting you're reading, each marked with whether its notes are written.
- After a call, the Notes tab walks you through it: first who spoke, with the longest thing each person said and a button to hear it, then writing the notes, then sending them.
- The recording screen has been rearranged. The time, both audio levels, your share of the talking, the notes style and Stop now sit in one strip across the top, and the right-hand side shows one thing at a time — key points, the live transcript or the shared screen — at full height, instead of four cramped cards and a transcript that cut off mid-line.
- The audio meters while recording are the same live waveform Dictator uses when you dictate, instead of flat bars. Each side stays grey until it's actually heard, and quiet rooms now read as quiet rather than filling half the meter.
- The Notes tab now only ever holds the final notes. Until they're written it opens with a Write notes button at the top of the page, rather than a draft with the button somewhere below it. The rough notes from the call always have their own Live notes tab, and the Details panel just shows whether the notes have been written.
- Meeting recordings no longer lose their last moments. Audio was written to disk through the same queue that draws the window, and stopping a meeting deliberately discarded whatever was still waiting there — usually the end, which is where the decisions tend to be. Audio is now written the moment it arrives, and stopping waits for the last of it to land before closing the file.
- Two more models can write meeting notes: Qwen 3.5 9B and Gemma 4 12B. Gemma 4 E4B is still the recommended one — it remains the model the notes are tuned against.
- New language models to choose from for the on-device provider: Qwen 3.5 in 2B, 4B and 9B sizes, and Gemma 4 12B. Older models (Llama 3.2 and Qwen 2.5) are no longer offered, but one you're already using stays selected and stays listed.
- New Demo mode in Settings swaps your meetings, notes, transcripts and people for fictional stand-ins while you record a video or take a screenshot; it switches off when Dictator Meetings quits.

## v2026.9.1 — 2026-09-07

- The notes assistant now knows the current date and time when answering questions or drafting follow-ups.
- Renaming a meeting no longer occasionally renames a different meeting: a title you type is now always applied to the meeting you typed it into, even if you click straight to another meeting in the sidebar, and clicking away saves the new title instead of losing it.

## v2026.9.0 — 2026-09-06

- Fixed: the meetings list could come up empty on launch because the window scanned for meetings before the app had pointed storage at your synced folder. Existing meetings were never touched; they just weren't listed.
- Dictator Meetings has its own app icon: the two-people-and-a-voice symbol from its menu bar item, in Dictator's blue, so the two apps are easy to tell apart in the Dock and the app switcher.
- The AI instructions field in Settings → General is a full-width, left-aligned text field that grows as you type.
- First standalone release. Meetings moved out of Dictator into its own app; your recordings, notes and settings carry over automatically.

