# Notch Island HUD — Planning Doc

Status: **planning**, sequenced as a prerequisite for `meeting-coach.md` phase 2 (the coach chip becomes this island's ambient mode — one overlay surface, not two panel systems).

## The idea

Restyle the dictation HUD as a Dynamic-Island-style surface: a black shape that pops down from the top of the screen with a spring animation, visually emerging from the notch on notched Macs. During meetings, the same island hosts the coach's ambient strip and nudges.

## Feasibility: HIGH — well-trodden macOS pattern (Boring Notch, NotchNook, Alcove), and our hard parts are already solved

The existing `HUDPanel` + `HUDController` (`UI/HUDController.swift`) already provide the genuinely fiddly pieces: non-activating borderless panel, `.statusBar` window level (which renders **above** the menu bar — no new level work needed), `crossSpaceBehavior` re-asserted per show to survive Space binding, mouse-cursor screen resolution (`activeScreen()`, `:169`), `ignoresMouseEvents` toggled per state, alpha fade show/hide. The island changes *where* the panel sits and *what the content looks like* — the window mechanics carry over nearly untouched.

## Design

### Geometry — `NotchGeometry` helper

Per-screen anchor computation:

- **Notched screens**: `NSScreen.safeAreaInsets.top > 0` detects the notch (macOS 12+). Notch width = screen width − `auxiliaryTopLeftArea.width` − `auxiliaryTopRightArea.width`. The island anchors flush to the top edge, horizontally centred on the notch, idle width = exactly the notch width — so the black shape and the physical notch read as one object, and the menu bar items either side stay visible/usable.
- **Non-notch screens** (externals — the common case on this desk): no notch to merge with, so the island is an intentional floating black pill, top-centre. Two sub-cases: transient dictation states sit flush to the top edge (over the menu bar, briefly — fine); the *long-lived* meeting ambient strip drops just **below** the menu bar instead, so it doesn't cover the clock/status items for an hour.

### Window & animation mechanics

- **Fixed-size transparent panel, animated shape inside.** The panel is sized once to the maximum expanded footprint with a clear background; the black island shape grows/shrinks within it via SwiftUI springs. We never animate the NSWindow frame — window-frame animation is jankier, and this codebase has already been bitten by aggressive AppKit window re-layout (the 2026-06-07 `_postWindowNeedsUpdateConstraints` crash; same lesson: keep window-level churn minimal, let SwiftUI do the motion).
- **Pop-down animation**: idle = notch-width sliver (or hidden); on activation the shape springs downward and outward to content size — reads as emerging from the notch because the top edge never moves and the notch area itself is physically black. Collapse reverses with a slightly faster ease. Respect `accessibilityReduceMotion` (fall back to the current fade).
- **Show/hide** keeps the existing outer alpha fade (`show()`/`hide()`, `:115-144`) wrapped around the inner spring — cheap insurance against half-rendered first frames.
- Content rendering follows the existing HUD discipline: observe coarse state only; per-tick values (meters) live in leaf views.

### What lives in the island

| State | Appearance |
|---|---|
| Idle, no meeting | Hidden (nothing renders; on notched Macs the notch is just the notch) |
| Dictation pipeline active | Pops down: waveform/state pill — the current `HUDView` content restyled black-on-island; cancel affordance unchanged |
| Meeting recording (coach on) | Persistent ambient strip: talk-ratio dot, elapsed, checklist `3/5` — the coach chip's §7 states, hosted here |
| Coach nudge fires | Island expands one line ("Budget not discussed yet"), auto-collapses ~8 s |
| Click during meeting | Expands to checklist + quick-add + metrics (the chip's expanded state, including the `canBecomeKey`-only-while-field-focused dance) |
| Dictation *during* a meeting | Dictation state takes the island; coach strip resumes after — one surface, priority to the transient |

### Multi-screen

Dictation keeps the mouse-cursor screen rule (it follows your attention at hotkey time). The meeting ambient strip pins to one screen for the meeting's duration — repositioning a persistent strip every time the cursor crosses displays would be noise. Default pin: the screen that was active at record start; revisit after real use.

## Module structure

```
Sources/Dictator/UI/Island/
  NotchGeometry.swift          # per-NSScreen: hasNotch, notchWidth, island anchor rect, ambient-mode offset
  IslandPanel.swift            # the NSPanel — HUDPanel's recipe (level/behavior/non-activating), max-size + clear
  IslandController.swift       # successor to HUDController: same withObservationTracking loop, now observing
                               #   pipeline state AND AppState.activeCoachEngine; owns precedence (dictation > coach)
  IslandView.swift             # the black shape + spring states; hosts DictationIslandContent / CoachIslandContent
  DictationIslandContent.swift # restyled HUDView content
  (CoachIslandContent comes with meeting-coach.md phase 2/3)
```

`HUDController`/`HUDPanel`/`HUDView` are replaced, not wrapped — the Escape/Tab monitors and state plumbing move across unchanged. `ScratchpadPanel` is untouched.

## Phases

1. **Island core + dictation**: geometry helper, panel/controller/view, dictation states restyled, pop-down animation, notched + non-notch handling, multi-screen rules. Ships as the new HUD. — **SHIPPED 2026-06-12** (`UI/Island/`; HUDController/HUDPanel/HUDView deleted, monitors carried over).
2. **Coach ambient mode**: lands with `meeting-coach.md` phase 2 — `CoachIslandContent` replaces that plan's `CoachChipPanel`/`CoachChipController` (its §7 view-state spec and focus rules apply verbatim; only the host changes). — **SHIPPED 2026-06-12** (ambient strip + nudge line; click-to-expand checklist arrives with coach phase 3).

## Open questions

- [x] Keep the old bottom-centre style behind a `hudStyle` setting? **Decided 2026-06-12: replace outright** — no fallback style; revisit only if the island annoys in practice.
- [ ] Island idle during a meeting on a notched Mac: exactly notch-width is invisible-by-design — is that *too* quiet for the ambient strip's habit-forming job? May want a 2–3 pt visible lip or subtle glow.
- [ ] Hover-to-peek (expand on mouse-over like the third-party notch apps) — nice later, not v1; interacts with `ignoresMouseEvents` toggling.
- [ ] Non-notch ambient pill below the menu bar: does it collide with apps that put content hard against the top (full-height browser tabs)? Check during dogfood.
