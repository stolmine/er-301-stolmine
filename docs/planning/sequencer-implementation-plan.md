# Sequencer — v0.1 implementation plan

**Companion to** `sequencer-spec.pdf` (architectural baseline). This document captures
implementation-level decisions and UI refinements made on top of the spec. Where this
doc and the PDF disagree, this doc supersedes — the PDF is a snapshot; this is the
working plan.

**Status:** v1 scope locked 2026-05-12 on `develop`. The 10 questions previously
listed as "deferred to implementation phase" are now resolved; see the **Locked
decisions** section below. New ambiguities surfaced during the lock-in pass are
captured in **Deferred ambiguities** (intentionally not blocking engine work).

---

## Architectural shift from the spec — sequencer is *not* a chain unit

Spec original framing: "implemented as a chain unit type, multiple instances via
standard unit instantiation."

**Revised framing:** sequencer is a **global firmware service** with virtual-jack
outputs in `Source/ExternalChooser`, alongside `IN1-4`, `G1-4`, `Ax-Dx`, `OUTx`.
**Fixed slot count: 4 sequencers** per patch (`seq1` through `seq4`), each with the
six outputs the spec defines.

Implications:
- No standard unit lifecycle, no per-instance inlets/outlets.
- Slot state is patch-level persistent (alongside settings, alongside other globals).
- Outputs are reachable from any chain destination's input picker globally — same
  semantic model as IN/G/OUT/A-D.
- Multiple instances = pre-allocated slots, not user-instantiated.

Reuses existing er-301 idiom: see `xroot/Source/ExternalChooser/init.lua:56-62`
where `addSourceGroup("INx", externals["INx"])` registers IN1-4 etc. Sequencer
adds `addSourceGroup("seq", externals["seq"])` with the same machinery.

C++ side: register `seq1.cv1, seq1.cv2, ..., seq1.steplen` etc. via
`app.getExternalSource(name)`. Engine writes current slot values into each source's
sample buffer at audio rate (sample-and-hold from tick boundary to tick boundary).

---

## L1 nulls vs zero — no nulls in L1, nulls in L2

**L1 cells: typed-zero default, no null state.** Empty cell emits the column's
typed zero. Spec rationale stands: nulls add ambiguity ("user meant skip" vs
"user forgot"), and the sustain use case is served explicitly by **shift+encoder
fill**. Composition control comes from the gate column — leave gate empty on rows
that shouldn't fire.

**L2 cells: optional / nullable.** Empty L2 cell genuinely means "no rule here."
This is the natural model for sparse rules — most cells are empty.

Implementation: L1 = `vector<value>` per column (zero-initialized);
L2 = `vector<Optional<Rule>>` per column.

---

## Drops from the spec

These are explicitly removed for v1:

1. **Compound predicates (AND/OR/NOT)**. L2 cell = always single
   `predicate : action`. Composing logic across multiple L2 cells is the
   workaround. This collapses the cell editor to a clean fixed 6-slot layout.
2. **Scroll-follows-playhead**. Polymeter makes this incoherent. Replaced with
   universal focus-head navigation (below).
3. **Compound expansion to 7-slot editor**. Falls out of #1.
4. **Per-platform UI variants**. v1 targets only **AM335x desktop** with the
   standard 256×64 main + 128×64 sub display. Portable variant (per
   `portable-hardware-spec.pdf`) is a separate scope.

---

## Two-axis navigation

**Focus-head row** — single, shared across all 6 plies. The ER-301 has
**one encoder**; it is dedicated to focus-head navigation in the
sequencer takeover. Plain encoder advances / retreats the focus head
universally; every ply moves in sync. Visualized as **full-row
background highlight** across all plies (e.g. `GRAY5` fb.fill).

**Column cursor** — which ply is "active." Direct jump via M1-M6
softkeys is the **only** column-movement input (M1 = ply 1, ..., M6 =
ply 6). There is no sub encoder; an earlier revision of this doc
mentioned one, but the hardware does not provide a second rotary.
Cursor's column is the target of cell-edit, mark-start/end, and clear
actions.

The two cursors are independent. Focus head defines the row; column
cursor defines the ply. Authoring intent (edit / mark / clear) acts on
the cell at `(focus_head_row, column_cursor)`.

---

## Loop-region indication per column

Per-column loop has a `start` row and `end` row. Cell rendering:

- Inside loop region: normal background, normal text
- Outside loop region (past start above or end below): **dim text** (e.g. `GRAY3`)
- Loop start row: thin line above cell (per ply)
- Loop end row: thin line below cell (per ply)
- Focus head: full-row background highlight across all plies (overlays everything)
- Playhead per ply: small `▸` glyph beside step number

All cells are scrollable (encoder navigates anywhere); loop bounds only affect
playback, not authoring access. User can edit cells outside the active loop —
useful when redefining the loop region.

---

## Mark-start / mark-end state machine

Per-column 3-state cycle for the loop-marking ply:

```
state A: no start, no end
  ply label = "mark start"
  press → set start = focus_head_row, transition to B

state B: start = N, no end (region in-progress)
  ply label = "mark end"
  press → set end = focus_head_row, transition to C
         loop region is [min(N, end), max(N, end)] — direction-tolerant

state C: start = M1, end = M2 (region active — steady state)
  ply label = "mark start"
  press → set new start = focus_head_row, transition to B (end invalidated)
```

Mutex per column: only one start, only one end at any time. Pressing "mark
start" while a region exists redefines the start and reopens loop for re-marking
the end.

**Direction tolerance:** the loop region always normalizes to
`[min(marker1, marker2), max(marker1, marker2)]`. The labels "start" and "end"
become "first marker" and "second marker"; the order in which the user presses
them does not affect the resulting loop region. 1-step loops
(`marker1 == marker2`) are valid and cause the sequencer to re-fire the same
cell on every tick (held-CV / single-step drone behaviors).

---

## Sub-display layout (3 plies, S1 / S2 / S3)

### Grid view, L1 mode

```
+--S1 ply (~42px)-+--S2 ply (~42px)-+--S3 ply (~42px)-+
|     +1.0        |   mark start    |   ▸ playhead    |   (default; clipboard empty)
|     EDIT ▸      |     ▸ mark end  |   (state-       |
|                 |     (cycles)    |    dependent)   |
+-----------------+-----------------+-----------------+
   S1 click =        S2 click =        S3 default = jump to playhead
   keyboard          cycles per-col    S3 with paste = paste clipboard
   modal on cell     state machine     S3 + shift = clear cell
```

### Grid view, L2 mode

S1 ply renders the predicate:action notation **vertically stacked** to fit 42px
width:

```
+--S1 ply (~42px)-+--S2 ply (~42px)-+--S3 ply (~42px)-+
|     %4          |                 |                 |
|      :          |   mark start    |   ▸ playhead    |
|     B+1         |    ▸ mark end   |   /paste/clear  |
|     EDIT ▸      |     (cycles)    |                 |
+-----------------+-----------------+-----------------+
```

Empty L2 cell: S1 ply shows "EMPTY — click to author."

### Cell-edit takeover (Keyboard.Slot fork) sub layout

When user clicks S1 to enter the modal cell editor:

```
+--S1 ply-----+--S2 ply-----+--S3 ply-----+
|  preview    |  NL desc    |             |
|  %4:B+1     |  every 4    |  CANCEL     |
|             |  passes,    |             |
|             |  add 1 to B |             |
+-------------+-------------+-------------+
   live render    NL description     S3 = exit
   of cell as     of focused slot    modal w/o
   it would       (M1-M6)            committing
   appear
```

### Selection mode (when shift+scroll has built a multi-cell selection)

```
+--S1 ply-----+--S2 ply-----+--S3 ply-----+
|             |             |             |
|   COPY      |   CUT       |   CLEAR     |
|             |             |             |
+-------------+-------------+-------------+
```

Sub returns to grid mode (L1 or L2) once an action is committed or selection is
cancelled.

---

## S3 ply state-rotation summary

| Clipboard state | Selection active | S3 default | S3 + shift |
|---|---|---|---|
| Empty | No | jump to playhead | clear cell |
| Empty | Yes | (sub in selection mode) | (sub in selection mode) |
| Non-empty | No | paste at focus head | clear cell |
| Non-empty | Yes | (sub in selection mode) | (sub in selection mode) |

Clipboard scope:
- **Single slot, ephemeral** (not persisted across patch save).
- Cross-column paste: type-checked. Paste preserves source column's type,
  refuses incompatible (CV→time = no, CV1→CV2 = yes).
- Layer-checked: L1 selections paste into L1 only; L2 → L2 only.

Selection mechanic:
- Hold **SHIFT** + encoder scroll extends selection range from focus head's current
  cell.
- Selected cells render with distinct background (inverted text or border).
- Sub display switches to the COPY/CUT/CLEAR layout.
- Exit selection: **CANCEL** hard button (or release shift, if shift-held model).

---

## Hard-button bindings within sequencer takeover

| Button | Behavior |
|---|---|
| HOME | Jump focus head to current playhead row (per cursor's column) |
| CANCEL (grid view, no cell editor open) | Jump focus head to row 0 |
| CANCEL (cell editor modal open) | Exit modal without committing |
| ENTER (cell editor modal open) | Commit cell, exit modal back to grid |
| ENTER (grid view) | (reserved — not currently used; could be "click cursor cell to edit" if encoder click isn't used for that) |
| **shift+ENTER** anywhere | **Toggle sequencer takeover on/off** (entry + exit) |
| UP | Toggle L1 ↔ L2 layer view |
| SHIFT | Modifier — extends selection on encoder scroll, modifies S3 to clear |
| Encoder click (grid view) | Open cell editor modal for cursor's cell |
| Encoder click (cell editor) | Commit current slot, advance cursor to next slot |

---

## Access paths

Sequencer takeover is an **alternate view of scope mode**. The 3-position
physical mode toggle is unchanged in behavior; scope mode internally has two
sub-views (`view = "scope" | "sequencer"`). **`shift+ENTER` from scope mode
is the only access path in v1.**

**Entry / exit:** `shift + ENTER` from scope mode toggles between scope's
default view and the sequencer takeover. **Exit binding is the same as entry.**
Single gesture to muscle-memorize, reversible.

**Persistence across mode-toggle changes:** the takeover survives mode-toggle
movement. Toggle to edit, work in chain editor, toggle back to scope. The
sequencer takeover is still showing. Only `shift+ENTER` returns scope mode to
the scope view.

**Cell-editor modal interaction with shift+ENTER:** modal absorbs it. Inside
the cell editor, `shift+ENTER` commits the cell and exits to the grid view
(does NOT exit takeover). User must press `shift+ENTER` again from grid view
to exit takeover entirely. This protects against accidental mid-edit exits.

**Excluded from v1 (decided 2026-05-12):**

- **Picker click dispatch.** Clicking a `seq*.cv1` source wires it as an input
  (normal external-source semantics) but does NOT enter the takeover. The
  sequencer UI is reachable only from scope mode.
- **PinView seq-pin.** No new `SeqPin.lua` control type. Sequencer slots are
  not pinnable in HoldMode for v1.
- **Admin menu entry.** Would confuse the conceptual location: sequencer state
  is patch-level (lives under user mode > scope, where the takeover renders),
  while admin scope is reserved for system / patch-independent settings.

---

## Cell editor (Keyboard.Slot fork)

Reuse `xroot/Keyboard/Slot.lua` pattern. Six `app.SlidingList` widgets aligned to
M1-M6 button centers, each 64px tall, full main-display takeover. Per-slot list is
type-aware:

| Slot | Content |
|---|---|
| M1 | Predicate type (`%`, `?`, `=`, `~`, `>`, `<`, `=` value-comp, `!` fire-this-tick, `=` changed-this-tick, `@` step-range) |
| M2 | Predicate operand A (column letter A-F, or numeric depending on M1 type) |
| M3 | Predicate operand B (numeric / column letter / unused depending on M1+M2) |
| M4 | Action type (`+`, `-`, `*`, `/`, `=`, `?`, `!`, `-` mute, `n` jump-this, `*n` jump-global, `.n` jump-self) |
| M5 | Action target column (B-F, where applicable) |
| M6 | Action operand (numeric / column letter / unused depending on M4+M5) |

Slots that aren't relevant for a given pred/action combination render as **"—"**
and the encoder skips them.

**Type-aware operand display** (shared with L1 cell-value rendering):
- CV column targeted: `+12 st`, `+1 oct`, `+C5`, etc. (per user's pitch-display pref)
- Time column targeted: `100ms`, `1/4`, `1/8`, `1/16`, `0.5beat`
- CV-only generic: `+0.5`, `-0.25`, `+1.0`

Format chosen by target-column type, not by operand type. Implementation: shared
`renderOperand(value, columnType)` helper.

---

## Visual layout — main display grid (256×64)

Six plies × 6 visible rows × 10px per row = 60px content + 4px chrome. Per ply
~42px wide (256 / 6). Step number ~16px, value ~26px (matches StepListGraphic
convention from `er-301-habitat/mods/spreadsheet/StepListGraphic.h`).

```
+---ply1---+---ply2---+---ply3---+---ply4---+---ply5---+---ply6---+
|01· +0.0 |01· C2   |01· ---  |01· 100ms|01· 127  |01·  1/8 |   ·  = focus head
|02▸ +1.0 |02▸ C2   |02  ---  |02▸ 120ms|02▸ 100  |02▸  1/8 |   ▸  = playhead per ply
|03  +0.5 |03  D2   |03  ---  |03  ─80ms|03   90  |03   1/8 |   ─  = dim (outside loop)
|04  +0.0 |04  E2   |04  ---  |04  100ms|04  127  |04   1/4 |
|05  -0.5 |05  C2   |05  ---  |05  100ms|05  127  |05  ─1/4 |
|06  ─+1.0|06  G2   |06  ---  |06   80ms|06  100  |06  1/16 |
+----------+----------+----------+----------+----------+----------+
   cv1       cv2        cv3       gate-len  gate-amp  step-len
```

L2 view: same grid shape, sparse, edge-strip color-coded different from L1.
Cell content as compact `pred:action` notation (e.g., `%4:B+1`, `?60:B!`, `>0.5:C*2`).

---

## Implementation pieces with file targets

### C++ engine layer (~2 weeks)

- `od/sequencer/Sequencer.h/.cpp` — main slot data structure (4 instances global)
  - `vector<L1Cell> columns[6]` per slot
  - `vector<Optional<L2Cell>> columns[6]` per slot
  - per-column `loop_start`, `loop_end`, `playhead_l1`, `playhead_l2`
  - `RNG state`, `tempo_source` enum
- `od/sequencer/PredicateEval.h/.cpp` — closed grammar evaluator
- `od/sequencer/ActionApply.h/.cpp` — closed grammar action applier
- `od/sequencer/TickScheduler.h/.cpp` — master tick generator, reads
  `step_length_column[playhead]`, fires next tick at correct interval
- `od/sequencer/SequencerSource.h/.cpp` — wraps `app.ExternalSource` for each
  output (`seq1.cv1`, `seq1.gate`, etc.). Engine writes sample-and-hold values.

### Picker integration (~0.5 week)

- `xroot/Source/ExternalChooser/init.lua` — add `addSourceGroup("seq", externals["seq"])`
- C++ registration of 24 external sources (4 slots × 6 outputs)
- `seq*` sources behave as standard external sources — wireable from any chain
  destination's input picker, no special click dispatch. Takeover is reached
  via scope-mode `shift+ENTER` (see Access paths).

### Patch persistence (~0.5 week)

- Slot state serialization in the existing patch save flow
- Quicksave round-trip including L1, L2, lengths, playheads, RNG state, tempo
  binding, mark-start/end state per column

### Grid view (~1.5 weeks)

- `xroot/Sequencer/GridView.lua` — fork StepListGraphic concept, render 6 plies
  with focus-head overlay, loop-region dim, per-column playhead markers
- Mode toggle L1↔L2 via UP hard button
- Edge-strip color indicator for active layer

### Cell-edit modal (~1.5 weeks)

- `xroot/Sequencer/CellEditor.lua` — fork Keyboard.Slot
- Six SlidingList widgets, type-aware option lists per slot
- Sub display: live notation preview + NL description + cancel
- Slot-skip logic for irrelevant slots

### Sub-display state machines (~0.5 week)

- `xroot/Sequencer/SubDisplay.lua` — routes between grid-mode (3 ply layout),
  selection-mode (COPY/CUT/CLEAR), edit-mode (preview/desc/cancel)
- Mark-start/end cycle per column

### Selection + clipboard (~1 week)

- Multi-cell selection mechanic (shift + encoder scroll extends from focus head)
- Single-slot clipboard (in-memory, not persisted)
- COPY / CUT / CLEAR / PASTE operations with type/layer checks

### Access path (~0.3 week)

- `shift+ENTER` toggle in scope mode (`xroot/Channels/Group.lua` scopeContext
  alt-view router). Single path; see Access Paths section for the rationale
  on excluded paths.

### Polish + bench (~1 week)

- Listen test under load — pattern consistency, glitch-free transitions
- Tempo sync verification (internal BPM, external clock-in)
- RNG reproducibility — same seed = same evolution
- Quicksave round-trips
- Multi-slot patches — independent operation, no cross-slot bleed

---

## Effort estimate

**~8.3 weeks** of focused development for v1, broken down:

| Piece | Estimate |
|---|---|
| C++ engine | 2 weeks |
| Picker integration | 0.5 |
| Patch persistence | 0.5 |
| Grid view | 1.5 |
| Cell editor modal | 1.5 |
| Sub-display routing | 0.5 |
| Selection + clipboard | 1.0 |
| Access path (scope-mode shift+ENTER only) | 0.3 |
| Polish + bench | 1.0 |
| **Total** | **~8.3** |

This is **focused**-time. Calendar time depends on context-switching with other
work; realistic delivery is **3-4 months**.

---

## Locked decisions (2026-05-12)

The 10 questions previously listed as "deferred to implementation phase" are
now settled. Engine and UI code should reference these directly.

1. **Loop minimum size.** 1-step loops are valid (`marker1 == marker2`). The
   sequencer re-fires the same cell every tick, supporting held-CV and
   single-step drone use cases.

2. **Loop direction tolerance.** Loops normalize to
   `[min(marker1, marker2), max(marker1, marker2)]`. The labels "start" and
   "end" become "first marker" and "second marker"; press order does not
   affect the resulting region. See the "Mark-start / mark-end state
   machine" section.

3. **Selection range.** `shift + encoder` defines a multi-cell selection
   (not a fill operation). Selection is bounded by column total length and
   ignores the loop region. All cell ops (COPY, CUT, CLEAR, fill-with-value)
   act on the selection.

4. **Tempo source.** Single global internal BPM, admin-set, applies to all
   4 slots. Engine runs at **4 PPQN** (1/16-note base tick). External
   clock-in is explicitly deferred to v2; v1 keeps slots output-only (no
   per-slot clock input).

5. **Clock granularity.** N/A for v1 (no external clock). Internal master
   tick = 1/16 note. Triplets and 1/32 are not supported in v1; would
   require bumping PPQN.

6. **PinView seq-pin.** Dropped from v1 (see Access paths > Excluded).

7. **L2 cell overflow rendering.** Truncate with `…` in grid view. Full
   content always visible in the cell-editor modal. Revisit during bench
   testing if real cells routinely overflow ply width (~42 px).

8. **Multi-instance picker indication.** None. `seq*` sources behave like
   IN1 / G1 / OUTx (shareable, no per-source "in use" badge).

9. **Default L2 cell template.** Empty. All 6 slots render `—` on cell
   creation; user picks predicate type first, then operands, then action.

10. **BPM display.** Always-visible header line within the sequencer
    takeover (small text at top of main display showing current BPM).

---

## Deferred ambiguities (surfaced 2026-05-12)

These were noticed during the v1 lock-in pass. None block engine work
(implementation sequence step 1). All converge during the cell-editor
implementation phase (step 5).

- **Predicate-symbol disambiguation.** The M1 predicate list under
  "Cell editor" contains three `=` entries (bare, `=` value-comp,
  `=` changed-this-tick). The third is a detector predicate, not a
  comparator. Cell-editor SlidingList content needs unique symbols per
  predicate type; reconcile when authoring M1.

- **Action-symbol disambiguation.** The M4 action list contains two `-`
  entries (subtract vs. mute) and `*` is overloaded between multiply and
  jump-global (`*n`). Possible resolutions: `M` for mute, `J` or `↺`
  for jump-global; reconcile when authoring M4.

- **Natural-language cell descriptions.** Sub-display layout for the cell
  editor shows `NL desc` (e.g. "every 4 passes, add 1 to B"). Source
  unspecified: hand-authored ~100+ strings (10+ predicates × 11+ actions),
  or template-generated from a grammar table? Template-generation is the
  default unless a hand-authored variant proves clearer in mockup.

- **StepListGraphic origin.** Plan cites
  `er-301-habitat/mods/spreadsheet/StepListGraphic.h` as the visual idiom
  to fork for the grid view. Habitat is a separate repo. Options: mirror
  the file into stolmine, build a compatible widget fresh in
  `xroot/Sequencer/`, or promote StepListGraphic into the firmware proper.
  Engine work proceeds either way; decide before grid-view work
  (implementation sequence step 4).

---

## Implementation sequence (concrete order)

1. **Engine first, no UI** — write the C++ slot data structure, predicate eval,
   action applier, tick scheduler, source-buffer emission. Test via direct
   register-poke from emu shell (Lua test harness). Prove the audio output is
   correct in a chain context. **2 weeks.**

2. **External source registration + picker integration** — surface `seq*.*` in
   the input picker. Verify they route to chain destinations. **0.5 week.**

3. **Patch persistence** — round-trip the slot state in quicksave. Catch any
   serialization edge cases early. **0.5 week.**

4. **Read-only grid view** — render L1 + L2 with playhead but no editing. Iterate
   the visual until it reads cleanly on the 256×64 main. **1 week.**

5. **Cell editor modal** — the meat of the UI work. 6-slot Keyboard.Slot fork.
   Paper-mockup the type-aware operand display first; then code. **2 weeks.**

6. **Sub-display state machines + mark-start/end** — wire up the 3-ply layout
   logic and per-column loop-marking cycle. **0.5 week.**

7. **Selection + clipboard** — shift+scroll selection, COPY/CUT/CLEAR ops,
   paste at focus head. **1 week.**

8. **Access path** — `shift+ENTER` toggle in scope mode, single path only.
   **0.3 week.**

9. **Polish + listen test** — under-load consistency, tempo sync, RNG reproducibility,
   patch quicksave round-trips. **1 week.**

---

## Test patches for bench

These specific patterns are useful for end-to-end verification of grammar and
runtime behavior:

- **Static 16-step CV pattern, single column** — basic sanity check for L1
  emission and clock.
- **Polymetric 5/7/12** — three CV columns with different lengths, verify LCM
  cycle and independent advancement.
- **L2 destructive write**: `%4 : B+1` — column B's value drifts upward every
  4th pass. Verifies stored-value action mechanics.
- **L2 transient fire**: `?60 : B!` — column B fires gate 60% probability.
  Verifies transient action mechanics.
- **L2 jump action**: `=8 : *0` — at step 8 of column A, jump all column
  playheads to row 0. Verifies playhead actions queue at tick boundary.
- **Clock from chain-side source** — sequencer step length sourced from
  external clock unit; verify it follows.
- **Quicksave reproduction** — save evolved L1 state after rules have drifted
  it, reload, verify identical playback.
- **All 4 slots simultaneously** — independent patterns, no cross-slot
  interference, all reachable from picker.

---

## Cross-references

- `sequencer-spec.pdf` — original architectural baseline (v1 spec)
- `xroot/Source/ExternalChooser/init.lua` — picker integration target
- `xroot/Keyboard/Slot.lua` — cell editor pattern to fork
- `er-301-habitat/mods/spreadsheet/StepListGraphic.h` — visual idiom to fork
  for grid (origin question: see Deferred ambiguities)
- `xroot/Channels/Group.lua` — scope-mode alt-view integration target

Earlier draft also referenced `portable-hardware-spec.pdf` (portable variant
hardware) and `xroot/PinView/` (PinView seq-pin). Both are out of v1 scope:
the portable spec lives on `rpidev` (not pulled to develop), and the PinView
pin is explicitly excluded per the Access paths section.
