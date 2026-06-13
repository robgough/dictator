# Meeting Screenshots — Planning Doc (feasibility stage)

Status: **planning**, decisions landing. Companion docs: `meeting-coach.md`, `meeting-context.md`.

Decisions so far:
- **Window-scoped capture is the primary mode.** Privacy, cleaner frames for hashing/OCR, and SCK delivers occluded/other-Space windows so the meeting needn't stay frontmost. Display capture survives only as an explicit user-picked fallback (`SCContentSharingPicker`) when the meeting window can't be resolved.

## The idea

Automatically capture screenshots of content shared during meetings — demos, presentations, slides — so every meeting folder carries a visual record alongside the transcript, with no manual effort.

## Feasibility: MEDIUM-HIGH — the capture is well-trodden API, the craft is in keeping only the frames that matter

Historical note: the original meetings plan (`meetings.md`) used ScreenCaptureKit for *audio* and even planned `ScreenRecordingPermission.swift`; the shipped implementation went CATap instead specifically to avoid SCK's app allow-list problem for audio. For *video* frames, ScreenCaptureKit is the right (and only sanctioned) tool, and none of the audio-side objections apply.

### Capture pipeline

- **`SCStream` at low frame rate** (~1 fps is plenty for slides/demos) running for the duration of the recording, started/stopped by `MeetingSession` alongside the two audio recorders.
- **Capture target — window-scoped, not whole-display.** `meeting-context.md`'s source-app detection identifies the meeting app; an `SCContentFilter` on that app's window captures shared content as rendered in the call, and *never* sees the user's other windows, notifications, or second display. Much better privacy story and much less junk to filter. Fallback: display capture with the same keyframe logic if the window can't be resolved (or the user picks via `SCContentSharingPicker`).
- **Keyframe selection, not video.** Per frame: downscale → perceptual hash → compare against last kept frame → keep only on significant change, with debounce (a slide must be stable for ~2s — skips scrolling/animation blur) and a per-minute cap. A talking-head grid produces near-zero keyframes (small hash deltas); a slide change produces exactly one. This is the difference between ~30 useful HEICs and a 500 MB frame dump for an hour-long meeting.
- **Timestamped filenames + index** (`screenshots/0142-00h23m12s.heic` + a JSON index with capture time and hash), so every screenshot pins to a position on the transcript timeline.

### Post-meeting enrichment (synergy with the other two plans)

- **OCR each keyframe** (Vision `VNRecognizeTextRequest`, local, fast) → searchable text per screenshot, stored in the index. Now "find the slide about pricing" works, and the final notes pass (`MeetingSummary`) can receive slide text as additional context — the notes can reference what was *shown*, not just what was *said*.
- OCR text doubles as the opportunistic participant/subject signal described in `meeting-context.md` (name labels, deck title pages).
- Optionally embed keyframes inline in `notes.md` / `transcript.md` at their timeline positions — the meeting folder mirrors are already markdown-native, so this is just image links.

### Costs & constraints (the honest list)

- **Screen Recording TCC** — the heaviest permission the app would hold. macOS 15+ shows the screen-sharing indicator while capturing and periodically re-prompts users to re-approve screen-recording apps; users must understand and *want* this. Strictly opt-in (`meetingCaptureScreenshots`, default off), with the purple-indicator behaviour explained in the toggle's description. New `NSScreenRecordingUsageDescription`-style honesty in Info.plist wording.
- **Storage**: with keyframe dedup, tens of HEICs per meeting — negligible next to the CAFs. Screenshots live in the **local** (per-Mac) meeting folder alongside audio, not synced storage, at least for v1.
- **Compute**: 1 fps downscale + hash is trivial CPU; no GPU/ANE contention with live ASR or live notes. SCStream setup adds a little to meeting start; do it concurrently with the audio warm-up in `.warmingUp`.
- **Privacy of others**: captured frames include other participants' video/shared content. Same posture as recording their audio (which the app already does, locally) — but auto-delete must cover screenshots too (`meetingAutoDeleteAfterDays` applies to the whole folder).
- **Detecting "is anyone even sharing?"**: not needed as a precondition — the keyframe selector naturally captures ~nothing when no one is sharing. Heuristics for share-detection can come later as an optimisation, not a correctness requirement.

### Integration points

- `MeetingSession.startRecording()` / stop — own the screenshot task lifecycle (mirroring how mic + system recorders are owned).
- New `MeetingScreenCapturer.swift` sibling to `MeetingAudioRecorder.swift`.
- `MeetingStorage.swift` — `screenshotsFolder()`, index URL, auto-delete coverage.
- `MeetingProcessor` — OCR pass after transcription, feeding the index (and optionally `MeetingSummary` context).
- UI: filmstrip in `MeetingDetailView` (click → timeline jump), thumbnails inline in the transcript at their timestamps.

## Proposed phasing

1. **v1 — Capture + filmstrip**: opt-in setting, window-scoped SCStream, keyframe selection, timestamped HEICs + index, filmstrip in the detail view, auto-delete coverage. — **SHIPPED 2026-06-13** (scaffolded end-to-end with sensible defaults; thresholds NOT yet validated against a real call — see note). Implementation:
   - **Setting**: `meetingCaptureScreenshots` (default OFF, synced) in a new "Shared screens" section of `MeetingsPane`. No Info.plist key needed — Screen Recording is a system-managed TCC grant with no usage-description string (unlike mic/calendar/system-audio).
   - **Permission**: `ScreenRecordingPermission` (CGPreflight/CGRequestScreenCaptureAccess + `Privacy_ScreenCapture` deep link). Quirk baked into the UX: the grant only takes effect after the prompt/relaunch, so the *first* meeting after enabling is audio-only; the next captures. The session requests the prompt and skips silently when not granted.
   - **Capture**: `MeetingScreenCapturer` (`@MainActor`) + a private `FrameSink` (`@unchecked Sendable`, all state on the SCStream sample-handler queue). 1 fps `SCStream`, `SCContentFilter(desktopIndependentWindow:)`. Window resolved from `SCShareableContent` filtered to `MeetingHostApps.hostBundleIDs` (the meeting/browser bundle-ID tables, extracted out of `MeetingSourceAppDetector` into shared `MeetingHostApps` — single source of truth), preferring the frontmost app's window, then largest. **No display fallback** — if no host window is on screen we capture nothing (conservative default; the plan's display fallback is deferred to avoid grabbing a private screen during a non-shared call). Capture size = 2× window points capped at 2560 long edge; HEIC at 0.7 quality.
   - **Keyframe selection**: 64-bit average hash (8×8 grayscale, luminance vs mean). Keep when Hamming distance ≥10 from last kept AND the change holds steady ≥2 s (debounce, kills scroll/transition blur), with a 1.5 s min interval and 8/min cap. First frame is baseline-only (meetings open on the non-shared call window). Incremental `index.json` write so a crash keeps what's captured.
   - **Storage**: `MeetingStorage.screenshotsFolder/screenshotIndexURL/readScreenshotIndex` — local (under `audioFolder`), so existing `deleteMeeting` + auto-delete folder removal already covers it; index filename shared as `MeetingStorage.screenshotIndexFilename`. `MeetingMeta.screenshotCount` (decodeIfPresent) is the badge count so UI needn't stat the folder.
   - **Lifecycle**: `MeetingSession` owns `screenCapturer` + `screenCaptureTask` — started after the audio recorders (in its own task so SCStream setup doesn't delay record-live), stopped in `stopRecording` (awaits the start task, flushes, sets `meta.screenshotCount`) and torn down in `onUnexpectedStop`.
   - **UI (post-meeting)**: `screenshotsSection` in `MeetingInspector` — a horizontal `ScreenshotThumbnail` strip (lazy off-main NSImage load, timestamp label, click opens full HEIC in the system viewer). Loaded via `.task(id:)` only when `screenshotCount > 0`.
   - **UI (live, added same day)**: `LiveScreenCapturePanel` in `LiveRecordingView`'s controls column shows which window is being captured + a thumbnail of the most recent kept frame + a "Change" menu to retarget. Needed the capturer to become `@Observable` exposing `currentTarget` / `latestScreenshotURL` / `isCapturing`; `FrameSink` gained an `onKeep` callback (hopped to main) that drives the live thumbnail; `availableTargets()` lists on-screen host windows and `switchTo(windowID:)` retargets via `SCStream.updateContentFilter` + `updateConfiguration` (reuses the sink so the keyframe count/dedup survive the switch), starting a fresh stream if auto-resolution found nothing. The change menu lists host-app windows only (same filter as auto-resolution); arbitrary-window / `SCContentSharingPicker` selection is a future option. The panel also surfaces the permission CTA when Screen Recording isn't granted.
   - **Per-meeting control (user-requested, same day)**: the global setting became the *default* ("Capture shared screens automatically"); the real control is now live and per-meeting. The capturer split `start` into `configure(folder:preferredBundleID:)` (always called at record start) + `enable()` / `disable()` — `disable()` genuinely tears the SCStream down so the system's purple capture indicator is honest about whether we're watching, while keeping the `FrameSink` so re-enabling continues the same index. `LiveScreenCapturePanel` is now shown for EVERY recording (not gated on the setting), with a Capture toggle + a **Capture now** button (`FrameSink.requestForceCapture` → `forceNext` flag → next frame kept bypassing the change/debounce/rate "discard" gates). `captureNow()` is a true one-shot when capture is off: `enable()` → force one frame → poll the observable `latestScreenshotURL` until it lands (≤~1 s at 1 fps, with a 2.5 s safety cap) → `disable()`, so no stream and no system capture indicator lingers for a one-off still. When capture is already on, it just forces a frame and leaves it running. The preview stretches the latest frame to full card width (height by aspect) and **Quick Look** (`.quickLookPreview`, needs `import QuickLook`) opens it full size — wired in both the live panel and the inspector filmstrip thumbnails (replaced `NSWorkspace.open`).
   - **NOT yet validated**: the hash/debounce/cap constants are educated defaults — couldn't tune against a real Zoom/Meet grid (test-data problem the user flagged). Also unverified at runtime: that window-scoped capture keeps delivering frames when the call is occluded / on another Space (SCK generally yes), and that the `SCContentFilter` survives browser tab/window moves. First real coached call with this on is the validation pass.
2. **v2 — OCR + search + notes integration**: Vision OCR into the index, screenshot text in meeting search, slide context fed to the final notes pass, inline images in markdown mirrors.
3. **v3 — smarter selection**: share-detection heuristics, region-of-interest cropping (capture the shared-content region rather than the whole call window).

## Open questions

- [ ] Browser meetings (Meet in Chrome): window-scoped is still the call, but the spike must verify the `SCContentFilter` survives tab moves / window merges; if it drops, re-resolve the window mid-meeting rather than falling back to display capture.
- [ ] Perceptual-hash threshold + debounce values — needs a spike with real Zoom/Meet calls (`scratch/` spike, per convention).
- [ ] HEIC quality/resolution: full retina is wasteful; 1x at ~0.7 quality probably right — verify slide text stays OCR-able.
- [ ] Should keyframes sync (they're small) while audio stays local? v1 says local; revisit with sync settle time.
- [ ] Does SCStream window capture keep delivering frames when the meeting window is occluded or on another Space? (SCK generally yes, but verify — it's the whole point of not requiring the window frontmost.)
