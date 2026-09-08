# Marketing site screenshots — outstanding shot list

Status: **six slots open** on `docs/index.html` — three in the **Mac** tab, three in the
**Meetings** tab. Each renders today as a dashed frame with a label and a "COMING" pill; no
image is requested, so there's no 404 and nothing fake is shown to a visitor.

This doc is the checklist for filling them in: what to shoot, how to get to that screen, and
the one-line edit that switches a slot on. Delete a section once its shot has landed.

## How to activate a slot (one line)

Every slot's `<img>` currently looks like this:

```html
<img data-shot="media/mac/hud-styles.png" alt="…" width="1600" height="1100" loading="lazy">
```

1. Save the screenshot at exactly the path in `data-shot` (create `docs/media/mac/` and
   `docs/media/meetings/` — they don't exist yet).
2. Change `data-shot=` to `src=` on that one line. That's it: the CSS rule
   `figure.shot img[src] + .shot-pending { display: none; }` hides the "coming" panel and
   `figure.shot img:not([src]) { display: none; }` stops hiding the image.
3. Optional tidy-up (second line, cosmetic only): remove ` shot--placeholder` from the
   enclosing `<figure class="shot shot--placeholder">` so the dashed border becomes the normal
   solid `.demo-frame` chrome.
4. Update `width`/`height` on the img to the real pixel dimensions of the file you saved
   (they're only there to reserve layout space, but wrong values cause a jump on load).

Find every remaining slot with: `grep -n 'shot--placeholder\|data-shot' docs/index.html`

## Capture settings (all Mac/Meetings shots)

- Retina (2×) capture — `⌘⇧4` then `Space` to grab a window (adds the macOS drop shadow), or
  `⌘⇧4` and drag for a tighter crop. Save as PNG.
- Crop to the window, not the desktop. Keep the shadow if you shoot with Space; otherwise
  leave a few px of margin.
- Keep every file under ~400 KB (the page's budget). `sips -Z 1600 in.png --out out.png`
  down-samples nicely; `pngquant`/ImageOptim if it's still heavy.
- Light mode is fine — the site frames screenshots in a card either way — but be consistent
  across the six.
- Anonymise: real names and real client content are visible in most of these screens.

---

## Mac tab

### 1. `docs/media/mac/modes.png`
- **Section**: `#modes` ("Styles & modes"), placed after the "Modes can auto-activate…" paragraph.
- **Caption already written**: "Modes in Settings. Drag to set precedence — the first one whose
  app list matches what you're typing into wins."
- **How to get there**: Dictator menu bar → Settings → **Dictation → Modes**.
- **State to stage**: at least four modes in the list (e.g. Quick / Standard / Polished /
  Messages), each showing its style badge, and at least one mode showing app-binding chips
  (bind Messages to Slack + Signal so the chips are visible).
- **Recommended size**: crop to the Settings window, about **1600×1100** at 2× (the placeholder
  reserves this ratio).

### 2. `docs/media/mac/assistant-draft.png`
- **Section**: `#assistant` ("Assistant mode"), at the end of the section.
- **Caption already written**: "Draft results land in a small floating window when there's
  nowhere obvious to paste them."
- **How to get there**: select nothing (or some text), hold the assistant hotkey, ask for
  something standalone — e.g. "draft a polite reply saying we can't make Thursday".
- **State to stage**: the floating result window with a readable drafted paragraph, over a
  recognisable app (Mail or a browser) so the context is obvious. Alternative if the floating
  window is awkward to catch: the menu-bar "Recent conversations" dropdown.
- **Recommended size**: crop to the window plus a little of the app behind it,
  about **1600×1000** at 2×.

### 3. `docs/media/mac/hud-styles.png`
- **Section**: `#fits` ("Fits how you work"), at the end of the section.
- **Caption already written**: "The HUD gallery in Settings. Each card shows what you'll
  actually see while you talk."
- **How to get there**: Settings → **General → HUD**.
- **State to stage**: all four cards visible (Notch island / Small island / Bottom pill /
  Mini badge) with the current selection highlighted. Scroll so the gallery isn't clipped.
- **Recommended size**: crop to the Settings window, about **1600×1100** at 2×.

> The Mac tab also carries one *real* screenshot — `media/scratchpad-meetings.jpg` in
> `#scratchpad` — which was kept as-is.

---

## Meetings tab

### 4. `docs/media/meetings/live-recording.png`
- **Section**: `#meetings-what` ("What it does"), first of the two slots.
- **Caption already written**: "Mid-call. The left side is already writing the notes; the
  right side is the transcript as it happens."
- **How to get there**: record a real (or staged two-device) call and screenshot while it runs.
- **State to stage**: live notes with a few real-looking bullets on the left, input level
  meters moving and the live transcript on the right, coach strip visible at the top,
  elapsed time on. Two speakers already separated is ideal.
- **Recommended size**: crop to the Meetings window, about **1600×1000** at 2×.

### 5. `docs/media/meetings/notes.png`
- **Section**: `#meetings-what`, second slot.
- **Caption already written**: "After the call: summary, discussion, decisions, and action
  items with an owner against each."
- **How to get there**: open a finished meeting → **Notes** tab (Final notes).
- **State to stage**: a meeting with a real structure — Summary, Discussion, Decisions, and
  Action items showing owner chips/checkboxes. A named meeting title (calendar-matched) sells
  the calendar feature at the same time.
- **Recommended size**: crop to the window, about **1600×1000** at 2×.

### 6. `docs/media/meetings/coach.png`
- **Section**: `#meetings-coach` ("The private coach"), at the end of the section.
- **Caption already written**: "The Coach tab, after the call. Never part of the notes,
  never part of an export."
- **How to get there**: open a finished meeting → **Coach** tab.
- **State to stage**: the talk-balance chart with a genuinely uneven split (it's more
  legible than 50/50), the key-points scorecard with a couple ticked and one missed, and the
  written read visible. Make sure no client-identifying content is in frame.
- **Recommended size**: crop to the window, about **1600×1000** at 2×.

---

## Worth adding later (no slot cut yet)

If you want more shots, the next most valuable are, in order:
1. The notch island mid-dictation, showing the live streaming transcript (would go in `#fits`).
2. The transcript page in Conversation / chat-bubble view (would go in `#meetings-what`).
3. History showing the per-stage breakdown of one dictation (would go in `#fits`).
4. The People editor with recognised voices (would go in `#meetings-what`).

To add one, copy any existing `figure.shot shot--placeholder` block, change `data-shot`,
the `alt`, the `.shot-pending-label` text and the `<figcaption>`.

---

## iPhone screenshots (already done)

`docs/media/ios-screenshots/{dictating,keyboard,scratchpad,history}.png` are derived from
`screenshots/6.7/*.png` with `sips -Z 600` (all 276×600). Regenerate after a UI change with:

```bash
for f in 03-dictating:dictating 05-keyboard:keyboard 07-scratchpad:scratchpad 04-history:history; do
  sips -Z 600 screenshots/6.7/${f%%:*}.png --out docs/media/ios-screenshots/${f##*:}.png
done
```

The row is deliberately four wide — a fifth wraps to 2+2+1 at desktop widths and the orphan
reads as broken.

Note: the current `07-scratchpad` capture shows a "Not syncing with your Mac" banner, so the
caption on the site is worded around it ("Point it at the same shared folder as the Mac…").
If you re-shoot with syncing configured, the caption can be simplified.
