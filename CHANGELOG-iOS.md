# iOS Changelog

User-facing changes to Dictator for iOS. Internal changes — refactors,
build tweaks, dependency bumps that don't change behaviour — don't belong
here. Style: a single sentence the user could read without context.

At release time the workflow extracts the `## Unreleased` section, uses it
as the App Store "What's New in This Version" copy, then moves it under
a `## v<version> — <date>` heading.

iOS uses the same YYYY.MM.N version scheme as the macOS app and the
website — year.month.count-of-releases-this-month — so the matching
release-tag conventions stay legible across platforms.

Inline markdown (bold, links, code) is not supported by the App Store
listing — keep entries as plain bullet lines.

## Unreleased

- Model download now warns you first if you're on cellular data so a 460 MB download doesn't blindside your monthly cap.
- New first-launch walkthrough that takes you through microphone access, downloading the speech model, installing the Dictator keyboard, and enabling Full Access in one place.
- About screen now credits NVIDIA's Parakeet TDT model alongside the FluidAudio library that runs it.
- About screen now shows a Your usage section: dictations, assistant turns, words spoken, words delivered, counted on-device.
- New Settings → Shared folder option. Pick a folder in iCloud Drive (typically iCloud Drive › Documents › Dictator on a Mac with Desktop & Documents syncing on) to share your custom vocabulary and usage stats with the Mac app or another iPhone signed into the same iCloud account. Dictation history and assistant conversations stay on this device only.
- Vocabulary editor moves into its own pushed page from Settings, with an entry-count badge on the link, so the Settings screen stops scrolling past the substitution toggles.
- Spoken-cue toggles (Punctuation, Numbers, Clock times, Currency, Emoji names) move to their own Substitutions page reached from Settings.
