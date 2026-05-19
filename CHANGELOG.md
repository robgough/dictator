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

- Added a "Learn Word in Dictator…" entry to the macOS Services menu — select a word in any app, right-click → Services, and a popup lets you add or update a custom-dictionary rule without opening Settings. The same action is also available from Spotlight and Shortcuts under "Learn Word in Dictator".
- Redesigned the Dictionary pane to handle large dictionaries: search field, alphabetical / as-entered sorting, compact single-line rows with hover-to-delete, and a help button that explains the per-rule options.
- Trimmed the menu-bar Recent list from 10 entries to 5 so the popup stays compact.
- Stopped the HUD's colours from drifting as the panel floats over different apps.
- Onboarding's primary buttons no longer look disabled when macOS is set to the Graphite accent.
- Formatting-LLM downloads now show smooth progress and finish as soon as the files land, instead of jumping to 100% and freezing there while the model loaded silently into RAM.
- Model downloads now show "Fetching metadata…" for the brief Hub-lookup window before the progress bar starts filling, so a slow first response doesn't look like a stalled download.
- Fixed the HUD sometimes failing to appear when a full-screen app is active, especially on a multi-monitor setup — the HUD now anchors to the screen containing the mouse cursor instead of relying on the foreground app's key-window screen.
