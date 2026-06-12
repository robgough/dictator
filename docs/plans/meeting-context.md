# Meeting Context & People — Planning Doc (feasibility stage)

Status: **planning**, decisions landing. Companion docs: `meeting-coach.md`, `meeting-screenshots.md`.

Decisions so far:
- **People/voiceprint store is a go.** Single feature toggle, default ON with meetings — not per-person opt-in (too onerous). Per-person delete still required.

## The idea

- Hook into the OS to know **which app** a meeting was recorded from (Zoom, Meet-in-Chrome, Teams, FaceTime…).
- Use **vision** to grab key information from the meeting window — participants, subject.
- Get **email/company** context — who are these people, what companies are involved.
- Once participants are known, **track people across sessions**: "find me everything I've talked to Jack about in the last week."

## Feasibility: MIXED — app detection is trivial, calendar beats vision for participants, people tracking is very feasible and the highest-value piece

### 1. Which app was the meeting in? — HIGH feasibility, hours not days

Two complementary signals, both cheap:

- **Core Audio process enumeration.** The meeting tap (`MeetingAudioRecorder.swift`) is a global mixer tap today, but Core Audio separately exposes the running audio-process list (`kAudioHardwarePropertyProcessObjectList`) and per-process properties (`kAudioProcessPropertyIsRunningOutput`, bundle ID). The codebase already touches this API family — `translatePIDToAudioProcessObject(pid:)` exists for excluding Dictator's own audio. Sampling "which processes are emitting output audio right now" at record start + periodically gives the actual meeting app even when it isn't frontmost. This is the strong signal.
- **`NSWorkspace.shared.frontmostApplication`** at record start — already used in `Pipeline.swift` for dictation context. Weak signal alone (user may be looking at notes), good tiebreaker. For browser-based Meet, the frontmost-window *title* (via AX, same machinery as `Injection/TextInjector.swift`) can distinguish "Google Meet" from generic Chrome.

Result stored as `sourceApp` (bundle ID + display name) in `meta.json`. Bonus: knowing the meeting app's window is exactly what `meeting-screenshots.md` needs for window-scoped capture.

### 2. Participants & subject — CALENDAR FIRST (high feasibility), vision later (brittle)

**The 80/20 here is EventKit, not vision.** Most real meetings exist as calendar events. Match the recording's start time against the user's calendar (±a few minutes window):

- Event **title** → meeting subject (better than LLM-inferring it; can also auto-suggest a coach preset).
- **Attendees** → names *and email addresses*.
- Email **domains** → companies involved ("two people from acme.com"). This answers the "could we get emails involved" idea without touching the user's mailbox at all — the invite already carries the emails. Actual mailbox integration (Mail.app has no public API; IMAP/JMAP means credentials and sync) is poor value next to this and should be out of scope.

Cost: Calendar TCC prompt (one `NSCalendarsUsageDescription` string + EventKit request) — a far lighter ask than Screen Recording.

**Vision/OCR of the meeting window** (ScreenCaptureKit capture + Vision `VNRecognizeTextRequest`, both local): genuinely possible, but per-app brittle — participant lists are panels that may be closed, scrolled, or renamed between app versions. Worth doing *opportunistically* once `meeting-screenshots.md` builds the capture + OCR infrastructure anyway: scrape name labels from captured frames as a supplementary participant signal, not the primary one. Don't build capture infra just for this.

**Speaker names from the transcript** (`MeetingSpeakerNamer.swift`) already exist as the third signal. Calendar attendees make it stronger: matching inferred names against the attendee list corrects ASR misspellings ("Jak" → "Jack Reeves <jack@acme.com>").

### 3. People across sessions — HIGH feasibility, biggest payoff

Two halves: identity and query.

**Identity — a persistent People store.** FluidAudio diarization already returns per-speaker voice embeddings (`speakerDatabase` in `MeetingProcessor.swift`), and the codebase already does cosine-similarity matching between embedding sets (cross-track merge at 0.78). Today embeddings are discarded after the merge. Instead:

- New `people.json` (synced storage, sibling of meetings): person records with id, display name, email(s), company, and a small set of voice embeddings (centroid + recent samples).
- At post-process time, match each meeting speaker's embedding against known people (same cosine machinery; threshold to be tuned — see `diarization_threshold_direction` lessons: validate against real multi-meeting data before trusting a number).
- Names attach from: manual rename in `MeetingInspector` (strongest), calendar attendees, transcript inference (`nameInferred` already distinguishes guess from fact).
- `meta.json` speakers gain an optional `personID`.

Voice-embedding re-identification across sessions/mics is the research-flavoured bit — same person on AirPods vs. Yeti will drift. Mitigations: store multiple embeddings per person, treat voice as *one* signal alongside calendar attendance, and always allow manual correction (which then improves the stored embeddings).

**Query — "everything I've talked to Jack about last week".** Once `personID` is on meetings, this decomposes into deterministic retrieval (filter meetings by person + date range — code, not LLM) followed by the existing meeting-assistant LLM path (`MeetingAssistantController` / the `assist()` machinery) synthesising over the matched meetings' notes. A person detail view (their meetings, timeline) falls out of the same index for free.

**Privacy posture (decided):** one single feature toggle ("People recognition" or similar), **default ON** when meetings are in use — per-person opt-in would be too onerous to be usable. This is consistent with the app's existing posture (it already records other participants' audio locally by default). Requirements that come with default-on: honest wording in the setting's description, per-person delete in the People UI that also purges stored embeddings, and turning the toggle off stops matching (existing store retained unless deleted). All on-device, nothing leaves the Mac.

## Proposed phasing

1. **v1 — Context capture**: `sourceApp` detection (Core Audio process list + frontmost), EventKit match → subject/attendees/companies into `meta.json`, shown in `MeetingInspector`. No new heavy permissions beyond Calendar.
2. **v2 — People store**: `people.json`, embedding persistence + matching, `personID` on speakers, manual link/unlink UI, single default-on toggle + per-person delete.
3. **v3 — Cross-meeting queries**: person filter in `MeetingsWindow` sidebar/search, "ask across meetings" via the assistant path.
4. **Later — vision-assisted participants**: piggyback on screenshot OCR (see `meeting-screenshots.md`), never as the primary signal.

## Open questions

- [ ] Embedding matching threshold + how many embeddings to keep per person (centroid vs. k-recent)?
- [ ] Does FluidAudio's embedding space stay stable across its model versions? A model upgrade may invalidate the store — need a schema/version stamp and a re-embed-from-audio story (audio is per-Mac local, so re-embedding can only happen where the audio lives).
- [ ] `people.json` is synced but embeddings come from per-Mac audio — confirm merge semantics when two Macs both add embeddings for the same person.
- [ ] Calendar matching: which calendars (all vs. selected)? Recurring events give the same title every week — fine for subject, weak for "what's different this time".
- [ ] Should companies be first-class (their own records) or just a derived field on people? Leaning: derived field for v1.
