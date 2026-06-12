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

1. **v1 — Capture + filmstrip**: opt-in setting, window-scoped SCStream, keyframe selection, timestamped HEICs + index, filmstrip in the detail view, auto-delete coverage.
2. **v2 — OCR + search + notes integration**: Vision OCR into the index, screenshot text in meeting search, slide context fed to the final notes pass, inline images in markdown mirrors.
3. **v3 — smarter selection**: share-detection heuristics, region-of-interest cropping (capture the shared-content region rather than the whole call window).

## Open questions

- [ ] Browser meetings (Meet in Chrome): window-scoped is still the call, but the spike must verify the `SCContentFilter` survives tab moves / window merges; if it drops, re-resolve the window mid-meeting rather than falling back to display capture.
- [ ] Perceptual-hash threshold + debounce values — needs a spike with real Zoom/Meet calls (`scratch/` spike, per convention).
- [ ] HEIC quality/resolution: full retina is wasteful; 1x at ~0.7 quality probably right — verify slide text stays OCR-able.
- [ ] Should keyframes sync (they're small) while audio stays local? v1 says local; revisit with sync settle time.
- [ ] Does SCStream window capture keep delivering frames when the meeting window is occluded or on another Space? (SCK generally yes, but verify — it's the whole point of not requiring the window frontmost.)
