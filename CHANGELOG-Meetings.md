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

- The AI instructions field in Settings → General is a full-width, left-aligned text field that grows as you type.
- First standalone release. Meetings moved out of Dictator into its own app; your recordings, notes and settings carry over automatically.
