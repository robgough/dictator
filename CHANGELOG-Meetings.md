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

_No changes yet._

## v2026.9.1 — 2026-09-07

- The notes assistant now knows the current date and time when answering questions or drafting follow-ups.
- Renaming a meeting no longer occasionally renames a different meeting: a title you type is now always applied to the meeting you typed it into, even if you click straight to another meeting in the sidebar, and clicking away saves the new title instead of losing it.

## v2026.9.0 — 2026-09-06

- Fixed: the meetings list could come up empty on launch because the window scanned for meetings before the app had pointed storage at your synced folder. Existing meetings were never touched; they just weren't listed.
- Dictator Meetings has its own app icon: the two-people-and-a-voice symbol from its menu bar item, in Dictator's blue, so the two apps are easy to tell apart in the Dock and the app switcher.
- The AI instructions field in Settings → General is a full-width, left-aligned text field that grows as you type.
- First standalone release. Meetings moved out of Dictator into its own app; your recordings, notes and settings carry over automatically.

