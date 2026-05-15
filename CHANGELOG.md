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

- Made the listening waveform on the HUD easier to see in light mode.
