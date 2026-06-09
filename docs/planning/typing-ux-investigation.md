# Typing UX investigation — running notes

Status: open / paused 2026-06-08. No active build. Predictive keyboard
branched + parked at `feature/predictive-keyboard` as an artifact of
the dead-end. Salvageable pieces noted at the bottom.

This document collects what we learned across a multi-turn design
session exploring whether the ER-301's text-entry interface can be
made meaningfully better than Grid or Slot. The headline outcome:
**no proposal currently survives bench impressions**, but several
threads narrowed and several principles solidified.

---

## The actual problem we were solving

Naming things on the ER-301: presets, units, control rebinds. The
existing dispatcher offers two methods:

- **Grid** — MondrianMenu of all letters; encoder walks a single
  cursor through 42-72 cells; M-tap inserts at caret.
- **Slot** — six vertical SlidingLists, one per M-key; press-and-hold
  M to lock a column, encoder scrolls within column, release commits.

User's stated stance going in: Slot has "fundamental issues" (revealed
during investigation to be the three-handed press-hold-encode-release
gesture, plus the lack of per-column specialization). Grid is "MVP"
but functional. The exploration goal was: can we do meaningfully
better.

---

## What we tried

### 1. Predictive keyboard (Thread 1)

Five alphabetical clusters on M1-M5 + digits/symbols on M6. Per
keystroke, recompute argmax(letter | last_char) for each cluster via
a static English bigram table; render the predicted letter big at
the top of the cluster, siblings smaller below. M-tap commits the
predicted letter. Hold M + scroll encoder cycles within the cluster;
release commits whichever letter is focused. Shift held swaps the
sub display to history-prefix-match completions on S1/S2 + a history
modal on S3.

Built, bench-tested, **rejected**. User's verdict:

> "this model is actually just too difficult to use ... requires a
> ton of reading through the subordinated letters and does not
> produce very intuitive results."

Failure analysis:

- 5 clusters means you scan 5 spatial positions to find your target
  letter. Alphabetical partitioning (a-e, f-j...) requires mental
  arithmetic on top of typing.
- The predicted-letter emphasis fights the siblings for visual
  attention. End up reading 30+ glyphs per keystroke to decide what
  to commit.
- Static English bigram predictions are wrong often enough on
  modular synth naming ("lpf2_v3", "tape-delay-fast") to be
  untrustworthy as a hint.
- The live preview on other clusters (Dasher-inspired "stable
  position, fluid emphasis") didn't translate to discrete 6-button
  hardware — it was noise the user had to ignore.
- Hold + scroll fallback re-introduced the same Slot complaint
  (effectively two-handed) when the prediction missed.

One real bug surfaced + fixed before the verdict: the live preview's
recompute was mutating the *held* cluster's prediction, so pressing
M1 with `e` visible would silently shift to `d` mid-press and commit
the wrong letter. Fixed by skipping the held cluster in the
preview-refresh. Bench guard test covers it. The bug fix didn't
change the verdict.

Code lives at `feature/predictive-keyboard` (commits `197f5e0`,
`f8b925f`):
- `xroot/Keyboard/Predictive/Bigram.lua` — static English bigram
  table + argmax/rank lookup, ~700 bytes of data, fast.
- `xroot/Keyboard/Predictive/Cluster.lua` — per-M-key cluster widget.
- `xroot/Keyboard/Predictive/HistoryModal.lua` — separate scrollable
  history browser with M-key cluster-jump for coarse seek.
- `xroot/Keyboard/Predictive/init.lua` — main Window.
- `xroot/sandbox/predictive_kb_bench.lua` — 5/5 isolation tests.

### 2. Cross-domain analog survey

After Predictive failed, stepped back to look for analogs in
medical, industrial, military, aerospace, consumer electronics,
and transportation. Decomposed the ER-301's user motions:

| Motion | What it really is |
|---|---|
| Select from a small set | M-buttons map to context-dependent options |
| Navigate a hierarchy | Drilling into chain → unit → control → sub-page |
| Adjust a value continuously | Encoder turns, cursor stays put |
| Commit / abort | Enter / Cancel |
| Monitor state while editing | Audio doesn't pause |
| Identify "where am I" | Spatially + modally |
| No-look operation when expert | Saved hand positions matter live |
| Symbolic manipulation | Patching, naming, sequencing |
| Pattern entry | Sequencer steps, scene authoring |

Most directly analogous interfaces by domain:

- **Aerospace MCDU** (Boeing/Airbus FMC) — line-select keys around a
  screen, context-sensitive, with a scratchpad pattern: compose
  freely, commit to a field via LSK. Closest single analog to the
  ER-301's M-key paradigm.
- **Test equipment** (Tektronix scope, R&S spectrum analyzer) —
  monochrome screen, single big encoder for all analog, fixed
  context-sensitive hardkeys around the screen. Form-factor twin to
  ER-301.
- **Medical** (anesthesia, IV pump, LIFEPAK) — massive reduction in
  degrees of freedom. Each control durably means one thing per mode.
- **Military HOTAS** — every physical position means exactly one
  thing forever; cycle through modes one at a time, never pick from
  a list; built for blind operation.
- **iDrive / COMAND / MMI** — one rotary controller + 4-8 hardkeys
  for top-level scope. Encoder push as universal commit. (ER-301
  doesn't have encoder push — rules this playbook out.)
- **Cameras** — generic hardware, user-customizable button mapping.
  Text entry consistently bad (deferred to phone/computer).
- **Bike GPS, motorcycle dash** — gloved operation forces massive
  labels + predictable button-to-action.
- **Octatrack / Polyend Tracker** — Elektron-adjacent peers. Accept
  deep modal everything as the price of few physical buttons.

Six principles emerged with consistency across domains:

1. **Durable position-to-meaning** beats smart remapping.
2. **The encoder is the only analog input.** Don't ask discrete
   buttons to do continuous selection.
3. **Cycle modes; don't pick them.** Sequential cycling is
   cognitively cheaper than menu selection.
4. **Reduce degrees of freedom.** Fewer well-chosen controls beats
   more options.
5. **Glance-readability is real estate.** Less stuff on screen,
   larger labels, more whitespace.
6. **Scratchpad + commit** beats type-and-go.

### 3. Realization: Grid already embodies most of these

The user pointed out, accurately, that these principles describe
Grid. Durable letter positions, encoder as sole analog input,
scratchpad-in-sub-display, glance-readable single highlighted
cursor. Grid survives as the default for a reason: it is the
principled answer.

The user's reaction to that realization:

> "even though it embodies principles solidly, i still think it
> sucks! it feels like the ultimate version of hunt and peck typing
> and an MVP."

Which is correct. Principled and good are not the same thing. Grid
is the mechanical satisfaction of the principles without the
ergonomic outcome they're supposed to produce. A calculator embodies
arithmetic without being pleasant to do long division on.

---

## Where we left off

User stated two directional preferences for the next iteration:

### Preference 1: ribbon-style alphanumeric filtering

The user specifically called out the **dense unit picker's alphabet
ribbon** (`xroot/Unit/Chooser/Dense.lua` around line 94) as a model
they like. That ribbon:

- 28 horizontal cells across the top of the 256-wide main display
  (~9 px per cell). 26 letters A-Z + a null position + a `#` bucket
  for numerics/specials.
- User encoder-scrolls the ribbon cursor; the list below filters to
  units whose title starts with the selected letter.
- HOME snaps to null, shift+HOME snaps to `#`.
- Ribbon counts (how many units match) lazily computed once.

What's good about it:

- **Single horizontal axis** = single encoder motion.
- **No reading per glance** — you see one alphabet at a known
  layout, scroll to a known position.
- **Compact** — a strip, not a grid; doesn't dominate the screen.
- **Filtering** (not selection) — the ribbon narrows the universe
  rather than picking a single thing. The user makes the final pick
  with a separate gesture on the narrowed list.

For typing this would translate to something like: **the alphabet is
a horizontal ribbon along the top edge; the encoder slides a cursor
across it; an M-key inserts whatever's currently under the cursor**.
That's a one-encoder-one-button-per-letter model. Closer to Grid's
linear traversal than Predictive's spatial cluster mess.

Open Q: does that just reduce to Grid laid out as a single horizontal
row, or does the ribbon's compactness buy something Grid doesn't have?

### Preference 2: Dasher-derived model, needs finessing

User leans toward Dasher's "stable position, fluid emphasis" but
acknowledges it didn't translate cleanly to the discrete predictive
keyboard. The continuous-probability surface is the inspiration; the
realization needs more thought.

What Dasher actually does (recap):

- Vertical column of letters where each letter's box-height equals
  its current probability given context.
- User drives a horizontal cursor to the right; the cursor's vertical
  position picks the next letter.
- Common letters are huge stripes, rare letters are razor-slits, but
  the **alphabetical position is stable** so the user is never lost.
- Originally a continuous gestural input (mouse / eye tracker).

Hard parts of translating to ER-301:

- **Single rotary encoder is not continuous in the same way as a
  pointer.** Each encoder tick is a discrete event. Dasher's
  pixel-by-pixel cursor motion has no direct discrete analog.
- **256×64 monochrome doesn't give the visual headroom** to render
  smooth box-height-by-probability, especially for 26+ letters.
- **No encoder push for commit** rules out the "let cursor land,
  click" gesture.

Possible adaptations to chew on:

- **Variable-rate encoder scroll along an alphabet ribbon.** Same
  layout as the dense picker's ribbon — 26+ cells horizontally —
  but the encoder's *cell-per-tick* rate varies by predicted
  probability. Tick the encoder through "e" slowly (many ticks of
  highlight time on `e`), blast through `q` in one tick. User's hand
  naturally lands on common letters. This is the discrete version of
  Dasher's variable-width boxes. Position stable, dwell-time fluid.
- **Variable-width ribbon cells.** Instead of even 9 px cells, common
  letters render as 14-18 px cells, rare letters render as 4 px
  cells. Same alphabetical order, same encoder traversal, but the
  cursor lingers visually on common letters because they're bigger
  targets. Could combine with above (variable rate AND variable
  width).
- **Two-stage: ribbon-filter then commit.** Encoder slides the
  ribbon cursor. M-key inserts whatever's currently under the
  cursor. The "predicted" letter is just the one the encoder lands
  on when you turn it lightly — emphasis is on dwell time, not on
  visual highlight contests.
- **Live history-match overlay.** As the user types, history entries
  starting with the current prefix glow on the ribbon at their first
  letter — a hint at where productive next-keystrokes live without
  overlaying any predictive emphasis on the ribbon itself.

The common thread: **borrow Dasher's probability-as-effort principle
without replicating Dasher's continuous gestural surface**. The
encoder is the surface; the probability shows up as physical
distance to traverse (variable rate) or visual cell size (variable
width) or both.

---

## Open threads not yet pulled on

Things mentioned in passing across the session that might still merit
investigation if the ribbon-Dasher direction doesn't pan out:

- **Chord input.** 5-of-6 M-button simultaneous presses give 32+
  unique chords. Single tap = full character. Brutal learning curve,
  very high expert ceiling. Wrong fit for casual users; right fit
  for people willing to learn for daily naming.
- **Name builder / morpheme picker.** Most ER-301 naming is recurring
  variations of a small invented vocabulary. A pick-root + pick-modifier
  + pick-suffix UI sidesteps typing entirely. Korg's name-generator
  pattern.
- **Canon Cat LEAP / search-as-typing.** Each keystroke filters the
  history list; M-key on a match commits the full match. Typing IS
  filtering. Closes the loop between Grid + the history modal.
- **Two-tap radial.** First M selects 6-letter group, second M picks
  letter within. 2 presses per letter, deterministic, no encoder.
  Predictable but slower than predictive's best case.
- **Off-device typing.** Names typed on phone/computer + synced via
  card or USB. Unsatisfying for live use but legit for studio. Many
  high-end synths quietly accept this defeat.

---

## What's in git

Predictive keyboard work parked on `feature/predictive-keyboard`
(commits `197f5e0`, `f8b925f`). Not yet decided whether to merge,
delete, or leave dormant. Salvageable components:

- `xroot/Keyboard/Predictive/HistoryModal.lua` — drop-in usable from
  any keyboard. Could be lifted to `xroot/Keyboard/HistoryModal.lua`
  and bound from Grid's shift+S3 if we go the "augment Grid"
  fallback route.
- `xroot/Keyboard/Predictive/Bigram.lua` — static English bigram
  ranking. Still useful for ranking history candidates when the
  history is sparse, or for variable-rate / variable-width ribbon
  cell sizing (the probabilities feed the cell-size function).

The Predictive keyboard shell + Cluster widget are throwaway.

---

## Decisions to defer

1. **Do we delete `feature/predictive-keyboard`?** Not yet. Git
   history is cheap; if a ribbon-Dasher direction needs the bigram
   data we already have it sitting there. Reassess in a future
   session.
2. **Is the keyboard the wrong abstraction entirely?** Maybe. The
   "name builder" direction would skip the typing problem altogether
   for the recurring-name case (the 80%). Worth a serious look before
   investing in another keyboard prototype.
3. **What's the next bench step?** Probably the ribbon-Dasher hybrid
   sketch, but only after the design questions above are answered.
