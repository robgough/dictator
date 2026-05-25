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
