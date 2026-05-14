# Sequencer — v0.1 implementation plan

**Companion to** `sequencer-spec.pdf` (architectural baseline). This document captures
implementation-level decisions and UI refinements made on top of the spec. Where this
doc and the PDF disagree, this doc supersedes — the PDF is a snapshot; this is the
working plan.

**Status:** v1 scope locked 2026-05-12 on `develop`. The 10 questions previously
listed as "deferred to implementation phase" are now resolved; see the **Locked
decisions** section below. New ambiguities surfaced during the lock-in pass are
captured in **Deferred ambiguities** (intentionally not blocking engine work).

**Progress (as of 2026-05-13):** Steps 1, 2, 3, 4, 5, 6, 7, 8 done.
Only Step 9 (polish + bench) remains. Branch `feature/sequencer`
carries the work; commits run from `ba75ad7` (engine) through
`bf2c312` (quicksave persistence). The sequencer is **end-to-end
user-authorable** on the device for both L1 patterns AND L2
predicate:action rules: wire any `seqN.*` source into a chain,
`shift+ENTER` from scope, navigate to a cell. On L1: ENTER to inline-
edit, encoder to nudge, shift+encoder for row-range selection, bare
encoder to bulk-edit, S1/S2/S3 for copy/cut/randomize, shift+S1 for
paste. On L2 (`shift+S3` to swap layer): ENTER opens the 6-slot cell
editor modal with column + row-pin targeting on operands, full
predicate / action grammar exposure (every op the engine evaluates),
live preview + NL gloss. Patch state survives quicksave round-trip
across power-cycle. Remaining: polish + bench (Step 9).

---

## Architectural shift from the spec — sequencer is *not* a chain unit

Spec original framing: "implemented as a chain unit type, multiple instances via
standard unit instantiation."

**Revised framing:** sequencer is a **global firmware service** with virtual-jack
outputs in `Source/ExternalChooser`, alongside `IN1-4`, `G1-4`, `Ax-Dx`, `OUTx`.
**Fixed slot count: 4 sequencers** per patch (`seq1` through `seq4`).

**Externally exposed outputs per slot (revised 2026-05-12):** `cv1`, `cv2`, `cv3`,
and `gate` (= the gate-amp envelope output). step-len and gate-len remain as L1
columns in the grid for authoring, but their effect is entirely INTERNAL: step-len
drives the tick scheduler, gate-len defines the gate envelope duration. They are
not patchable into other chains. The picker therefore shows 4 sources per slot
(16 total across 4 slots) rather than the originally specified 6 (24 total).

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

### Grid view, L1 mode (as shipped)

```
+--S1 ply-----+--S2 ply-----+--S3 ply-----+
|             |             |             |
|  start|stop |    mark     |     —       |   (default; no overlay)
|             |             |             |
+-------------+-------------+-------------+
   S1 = transport      S2 = enter mark    S3 = unused
   (Toggle play /      modal on the       (playhead reset
    stop on slot 0)    cursor's column     moved to
                                           shift+HOME)

Mark modal (after 1st S2 press):
+-------------+-------------+-------------+
|  start|stop |    end      |     —       |
+-------------+-------------+-------------+
   S2 commits live (firstMark..focusHead) to the column's
   normalized (lo, hi) loop pair on second press.

Shift held + clipboard non-empty (no other modal):
+-------------+-------------+-------------+
|    paste    |     —       |     —       |
+-------------+-------------+-------------+
   S1 = paste at focus head, advance focusHead by N
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
|   COPY      |    CUT      |   RANDOM    |
|             |             |             |
+-------------+-------------+-------------+
```

Sub returns to grid mode once an action is committed or selection is cancelled.

**Selection scope (revised 2026-05-12):** selection is a **row-range within a
single column** (the active column cursor), not a 2D rectangle. The selection
anchor is the focus-head row when `shift+encoder` first extends it; the
selection grows / shrinks as the encoder rotates.

**Bulk edit (no sub action):** if the user does NOT press a sub button while
the selection is active, the bare encoder (without shift) edits **all selected
cells uniformly**. The top-of-selection cell is the "master." On the first
encoder turn after selection is built, the master takes the increment AND every
other selected cell SNAPS TO the master's new value (i.e., the selection
becomes a constant fill at that value). Subsequent turns increment the master
and every cell follows. Conceptually: "set selection to a constant the user
can then dial."

**Sub buttons:**
- S1 = COPY (writes selection to clipboard, leaves cells unchanged)
- S2 = CUT (writes selection to clipboard, sets cells to zero)
- S3 = RANDOMIZE (replaces each selected cell with a random value in the
  column's typed range; CV columns randomize within +/- 5 V, gate-amp within
  0..1, gate-len/step-len within the common-fraction set, etc.)

**PASTE (shipped 2026-05-12):** lives on a **live shift-held overlay** on
the default (no-selection) sub bar, not on S3. While shift is held AND the
clipboard is non-empty, the sub labels swap from `start|stop / _ / reset`
to `paste / _ / _`; releasing shift restores the default. Pressing
shift+S1 writes the clipboard values into rows
`[focusHead .. focusHead + N - 1]` in the user's current column, then
advances focusHead by N (chained pastes stitch contiguously). Type-check
is by column category (`cv` for col 0/1/2, `time` for col 3/5, `amp` for
col 4); cross-category paste refuses silently. Selection mode takes
priority over the shift overlay — while selecting, shift only affects
encoder gestures.

---

## Sub-bar state-rotation summary

The default sub bar is `start|stop / mark / _`. Three overlays swap it:

- **Selection mode** (shift+encoder built a row-range): replaces all three
  ply with `copy / cut / rand`.
- **Mark modal** (1st S2 press; 2nd press / UP / ENTER / column-switch
  commits): S2 reads `end`; S1 keeps transport active; S3 blank.
- **Shift-paste overlay** (shift held + clipboard non-empty, no other
  modal): S1 swaps to `paste`; S2 / S3 blank.

Priority: selection > marking > shift-paste > default. Resolved per
refresh from gesture state.

| Selection | Marking | Clipboard | Shift | S1 | S2 | S3 |
|---|---|---|---|---|---|---|
| No  | No  | Empty     | No  | start\|stop | mark      | — |
| No  | No  | Empty     | Yes | start\|stop | mark      | — |
| No  | No  | Non-empty | No  | start\|stop | mark      | — |
| No  | No  | Non-empty | Yes | **paste**   | —         | — |
| No  | Yes | (any)     | (any) | start\|stop | **end** | — |
| Yes | —   | (any)     | (any) | copy        | cut       | rand |

S3 reset was removed; **playhead reset is now shift+HOME** outside the
L1 cell editor (`zeroReleased`). Inside the editor, shift+HOME keeps
its existing role as the "zero this cell" gesture.

Clipboard scope:
- **Single slot, ephemeral** (not persisted across patch save).
- Cross-column paste: type-checked by column category (cv = col 0/1/2,
  time = col 3/5, amp = col 4). Cross-category paste refuses silently.
  Same-category cross-column paste OK (CV1 → CV2 ok, gate-len → step-len
  ok), since the engine values are float-compatible.
- Layer-checked: L1 selections paste into L1 only; L2 → L2 only. (L2 not
  yet built; the clipboard is L1-only in practice.)

Selection mechanic:
- Hold **SHIFT** + encoder scroll extends selection range from focus head's
  current cell.
- Selected cells render with a dotted-edge selection box; the cursor box
  pins to the top-of-selection (= master) cell.
- Sub display switches to `copy / cut / rand` layout.
- Bulk-edit during selection: bare encoder writes `master + step` to every
  cell in the selection. Dirty marker (small dot on right edge) appears
  on each modified cell.
- Exit selection: **CANCEL** reverts bulk edits to the pre-edit snapshot
  and clears the selection; **UP** commits (keeps values, clears markers);
  switching columns via M1-M6 or entering ENTER-edit-mode implicitly commits.

---

## Hard-button bindings within sequencer takeover

The ER-301's encoder is **rotation-only** (no integrated push button),
so every "encoder click" pattern from sister modules (teletype, etc.)
has to be remapped here. ENTER takes the role of "open editor for
the cell at the cursor"; commit-and-advance within the cell editor
modal also rides on ENTER (with the modal absorbing the gesture so
shift+ENTER doesn't bubble out).

| Button | Behavior |
|---|---|
| HOME | Jump focus head to current playhead row (per cursor's column) |
| CANCEL (grid view, no cell editor open) | Jump focus head to row 0 |
| CANCEL (cell editor modal open) | Exit modal without committing |
| ENTER (grid view) | **Open the cell editor modal for the cell at `(focus_head_row, column_cursor)`** |
| ENTER (cell editor modal, no slot focused) | Commit cell and exit modal back to grid |
| ENTER (cell editor modal, M-slot held) | Commit currently-focused slot, stay in modal, advance slot cursor |
| **shift+ENTER** anywhere | **Toggle sequencer takeover on/off** (entry + exit) |
| UP (grid view) | Toggle L1 ↔ L2 layer view |
| UP (cell editor modal) | Exit modal without committing (alias for CANCEL) |
| SHIFT | Modifier — extends selection on encoder scroll, modifies S3 to clear |
| M1-M6 (grid view) | Direct jump for the column cursor |
| M1-M6 (cell editor modal) | Hold to focus that slot for encoder edit; release to release focus |

**Visual cursor: a box around the cell at `(focus_head_row, column_cursor)`.**
Without an encoder push, the user needs an unambiguous signal of which
cell ENTER will open. The active-column header highlight + focus-row
brightness together imply it, but a thin outline around the actual
target cell makes the gesture-target explicit, especially on layouts
where the highlighted row spans the full width. Implementation: a small
`app.Drawing` (or rectangle primitive) whose position updates with
`columnCursor` and `focusHeadRow` each refresh tick.

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

**~8.3 weeks** of focused development for v1. Status snapshot 2026-05-13
(approximately ~7.3 of 8.3 weeks shipped):

| Piece | Estimate | Status |
|---|---|---|
| C++ engine | 2 weeks | ✅ shipped (`ba75ad7`) |
| Picker integration | 0.5 | ✅ shipped (`ba75ad7`, trimmed `763296b`) |
| Patch persistence | 0.5 | ✅ shipped (`bf2c312`) |
| Grid view | 1.5 | ✅ shipped (`f8be7a7` … `22d7b01`) |
| Cell editor (L1 inline + L2 modal) | 1.5 | ✅ shipped (`ede9963`, `721a8e8`) |
| Sub-display routing | 0.5 | ✅ shipped (`bf30bfe`, `864b251`, `0b47789`, `3bf71d8`) |
| Selection + clipboard | 1.0 | ✅ shipped (`e7aaea3`, `22d7b01`, `bf30bfe`, `864b251` -- Chunks A/B/C + PASTE) |
| Access path (scope-mode shift+ENTER only) | 0.3 | ✅ shipped (`ade1f44`) |
| Polish + bench | 1.0 | ⏳ pending |
| **Total** | **~8.3** | **~7.3 shipped, ~1.0 remaining** |

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
   per-slot clock input). The v2 admin UX + engine wiring is sketched
   under **External clock + reset (v2 spec)** below.

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

11. **PASTE binding.** Lives on a live shift-held overlay on S1 of the
    default (no-selection) sub bar: `start|stop / mark / _` swaps to
    `paste / _ / _` while shift is held AND the clipboard is non-empty.
    Transport stays positionally consistent (S1 unshifted always =
    start/stop). Selection mode is never affected by this overlay --
    while selecting, shift only modifies encoder gestures. Decided
    against the alternative of moving transport to S2 (would break
    scope-mode reflex). Shipped in `864b251`.

12. **Mark-start/end modal.** S2 enters a per-column modal: 1st press
    snapshots the existing `(marker1, marker2)` pair into `markBackup`
    and plants `markFirstMark` at focusHead; encoder + HOME during the
    modal live-update marker2 so the loop dim slides with the user;
    2nd S2 press / UP / ENTER / column-switch via M-key all commit the
    normalized `(min, max)` pair and exit; CANCEL reverts to the
    snapshot. The shared dotted-edge primitive used for selection
    wraps the live `(firstMark..focusHead)` range while the modal is
    active. Cursor box turns white during marking (same active-state
    cue used for edit / selection modes). Shipped in `0b47789`,
    `3bf71d8`.

13. **Playhead reset gesture.** Moved off the sub bar to
    **shift+HOME** outside the L1 cell editor. Inside the editor,
    shift+HOME retains its prior "zero this cell" behaviour. The S3
    softkey is now unused (reserved for future per-state-machine
    needs). Shipped in `0b47789`.

---

## External clock + reset (v2 spec)

v0.1 ships internal-clock-only (locked decision #4). The v2 path lets
the user drive the sequencer from an external clock signal and an
external reset signal, both routed through the standard jack picker.
Single global tempo source (= matches the BPM model -- one source for
all 4 slots).

### Admin menu surface

Add a **Sequencer** section to the admin menu (alongside Settings,
Quicksaves, etc.). Inside, a **Clock settings** entry opens a
sub-page laid out like the system-settings menu (one row per option):

```
+--- Clock settings ----------------------------+
| Clock source          [ internal | external ] |
| External clock jack   [ none / G1 / G2 / ... ]|
| External clock div    [ 1 / 2 / 3 / 4 / 6 / 8]|
| Reset jack            [ none / G1 / G2 / ... ]|
+-----------------------------------------------+
```

- **Clock source** -- toggle between `internal` (BPM-driven) and
  `external` (rising-edge driven). When external, the BPM Settings
  entry can stay visible but is informational only.
- **External clock jack** -- jack picker entry. Reuses the existing
  `Source.ExternalChooser` flow (`xroot/Source/ExternalChooser/`); a
  user picks G1..G4, IN1..IN4, or any other gate-class external
  source. None = clock disabled.
- **External clock div** -- integer divisor (1..8 or so). The
  sequencer fires one tick every Nth external rising edge. Useful
  when the upstream clock is at a higher PPQN than our 4 PPQN.
- **Reset jack** -- separate jack picker. On rising edge: all
  playheads return to their loop minimums (equivalent of pressing
  shift+HOME to reset playheads, applied to every slot).

### Engine wiring

`Sequencer.h` gets a few new fields on `Slot` (or hoisted to
`SequencerTask` since they're slot-shared):

```cpp
// Clock source mode -- the sequencer either runs on internal BPM
// scheduling (samplesUntilTick countdown driven by setBpm) or on
// rising-edge detection from an external gate input.
enum ClockSource : uint8_t {
  CLOCK_INTERNAL = 0,
  CLOCK_EXTERNAL = 1,
};
ClockSource clockSource = CLOCK_INTERNAL;

// External clock input edge detection. The Lua side hands us an
// Inlet pointer when the user picks a jack; processFrame samples it
// and counts rising edges. extClockDiv = N means we fire one tick
// every N edges.
od::Inlet* extClockInlet = nullptr;
int        extClockDiv   = 1;
int        extClockEdgeCounter = 0;
float      extClockLastSample  = 0.0f;

// External reset input.
od::Inlet* extResetInlet      = nullptr;
float      extResetLastSample = 0.0f;
```

`processFrame` adds an external-clock branch:

- For each sample in the frame, read `extClockInlet`'s value at
  that sample.
- Detect rising edge: previous < 0.5 && current >= 0.5 (gate
  threshold).
- On edge: increment `extClockEdgeCounter`; if `>= extClockDiv`, fire
  `fireTick()` and reset counter.
- Detect rising edge on `extResetInlet` similarly: on edge, call
  `reset()` on every slot.

The existing sample-accurate processFrame loop (item 9 from Step 9)
naturally accommodates this: the frame is already being split at
tick boundaries; external-clock just becomes another tick-emit
trigger.

### SequencerTask + Lua surface

- `SequencerTask::setClockSource(int mode)` / `clockSource()` getters.
- `SequencerTask::setExtClockInlet(od::Inlet*)` /
  `setExtResetInlet(od::Inlet*)` -- accept SWIG-bound inlet pointers
  from the picker.
- `SequencerTask::setExtClockDiv(int)` / `extClockDiv()`.

Lua side adds:
- `xroot/Sequencer/AdminMenu.lua` -- the Clock settings page. Forks
  the MondrianMenu pattern used by system settings.
- Settings entries persisted via the standard `Settings` module so
  the clock-source pick survives reboot. Jack picks may need a
  bespoke serializer (storing the source name rather than the
  pointer).
- `xroot/AdminMode/Menu.lua` -- add the **Sequencer** section entry
  pointing at the new menu.

### Effort estimate

~1.0 week focused:
- Admin menu wiring + Clock settings sub-page: ~0.2w.
- Jack-picker integration for clock + reset (reusing
  `Source.ExternalChooser`): ~0.2w.
- Engine rising-edge detection + reset wiring + division logic: ~0.3w.
- Settings persistence + boot-time restore of clock config: ~0.1w.
- Listen test + interop verification with common external clock
  sources (modular gate at 1/16, 1/8, 1/4 etc.): ~0.2w.

### Open design questions

- **Should the internal BPM display be dimmed when external clock
  is active?** Probably yes -- BPM is moot in external mode.
  Alternative: display "extBPM" computed from edge intervals so the
  user sees the effective tempo.
- **External clock jitter handling.** A modular gate clock is not
  sample-accurate (jitter from analog source). Should we add a
  smoothing/PLL to stabilize tick intervals, or run "as-is" so the
  sequencer follows the source faithfully (warts and all)?
  Probably as-is for v2.0; PLL is a v2.1+ refinement.
- **Reset behavior during a running pattern.** Hard-reset to
  loop-min on rising edge, or queue the reset for the next tick
  boundary? Hard-reset is closer to user expectation but can
  produce audible clicks if the gate is mid-envelope.

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

- **StepListGraphic origin.** _Resolved 2026-05-12._ Built fresh in
  `xroot/Sequencer/GridView.lua` using stock `app.Label` / `app.Drawing`
  / `app.DrawingInstructions` primitives. No fork of Habitat's
  `StepListGraphic.h` was needed; the widget is Lua-only, ~700 lines,
  and depends on no C++ additions beyond the engine. The earlier
  cross-reference to Habitat stands as a visual-idiom citation only.

---

## Implementation sequence (concrete order)

1. ✅ **Engine first, no UI** — C++ slot data structure, predicate eval, action
   applier, tick scheduler, source-buffer emission. Verified via Lua bench
   harness (`xroot/sandbox/sequencer_bench.lua`): static-16-step-cv,
   polymetric-5-and-7, l2-destructive-mod2-add1 all PASS on every boot.
   Shipped in `ba75ad7`. **Step 1 done.**

2. ✅ **External source registration + picker integration** — 24 `seq*` sources
   (4 slots × 6 outputs) registered via `xroot/boot/app-setup.lua` and grouped
   in `xroot/Source/ExternalChooser/init.lua` as `seq1`..`seq4`. Wireable
   from any chain's input picker. Shipped in `ba75ad7`. **Step 2 done.**

3. ✅ **Patch persistence.** `xroot/Sequencer/Persist.lua` serializes
   per-slot state (length, markers, dense L1 cells, sparse L2 rules
   with row pins) into `data.sequencer`, hooked into
   `xroot/Persist/QuickSavePreset.lua` `populate()` / `apply()`.
   On load: each slot is force-stopped, stale cells cleared, saved
   state applied via existing engine setters, then `resetSlot` clears
   transient state. Skipped (per locked decisions): RNG state,
   running flag, all transient runtime fields. Bench includes a 5th
   `test_persistence_roundtrip` test exercising both predicate +
   action row pins. Shipped in `bf2c312`. **Step 3 done.**

4. ✅ **Read-only grid view** — `xroot/Sequencer/GridView.lua`. Six column
   headers ("name:NN" with live playhead row counter), 6-row × 6-column cell
   grid (font 9, 9 px pitch), 2-digit row ruler at the right edge.
   Brightness-encoded state (out-of-loop / in-loop / focus / playhead /
   focus+playhead modelled on teletype's pattern_mode.c). Cursor box outlines
   `(focusHeadRow, columnCursor)`. Scope-mode `shift+ENTER` is the single
   access path. Encoder threshold matches `Env.EncoderThreshold.Default`.
   Shipped across `f8be7a7` → `ede9963`. **Step 4 done.**

5. ✅ **Cell editor (L1 inline + L2 modal).** L1 inline edit shipped in
   `ede9963`: ENTER toggles "editingL1", encoder nudges by per-column
   step, dial button cycles fine/coarse, shift selects super, shift+HOME
   zeros the cell, ENTER while editing commits + advances focusHead
   (Habitat-fluid). **L2 modal** shipped in `721a8e8`:
   `xroot/Sequencer/CellEditor.lua` -- six tap-to-focus slots in the
   order `predColA / predOp / predOperand / actTarget / actOp /
   actOperand` so each side reads naturally (`A=3.5`, `B+1`). Cell-ref
   slots (M1 / M4) support row pinning -- bare encoder increments row
   index, S3 held + encoder cycles column letter, HOME clears the pin.
   Engine struct extended with `Predicate.colARow` / `Action.targetRow`;
   pin defaults to -1 (use that column's playhead). `setL2` grew two
   args; `l2PredColARow` / `l2ActTgtRow` getters added. Live preview on
   S1 + IF / THEN NL gloss on S2 / S3. shift+ENTER commits + advances
   focusHead + stays in modal for Habitat-fluid sweep authoring.
   **Step 5 done.**

   L2 fire indicator (Phase 2 polish): `Column.lastL2FiredRow` set in
   `fireTick` step 3 when a rule evaluates true. GridView L2 layer
   tracks per-column decay (~180 ms at 55 Hz) and renders a 2x2 dot on
   the cell's right edge -- same primitive as the L1 dirty marker.

6. ✅ **Sub-display state machines + mark-start/end.** Sub bar swaps
   between selection (`copy / cut / rand`), mark modal
   (`start|stop / end / _`), shift-paste overlay (`paste / _ / _` when
   clipboard non-empty), and default (`start|stop / mark / _`).
   Priority order: selection > marking > shift-paste > default. S2
   drives a per-column mark modal: 1st press snapshots the existing
   `(marker1, marker2)` and plants `markFirstMark` at focusHead;
   encoder + HOME during the modal live-update marker2; 2nd press / UP
   / ENTER / column-switch commit the normalized `(lo, hi)` pair;
   CANCEL reverts to the snapshot. The same dotted-edge primitive
   used for selection wraps the live `(firstMark..focusHead)` range.
   S3 reset button was reclaimed; **playhead reset moved to
   shift+HOME** outside the L1 cell editor (zeroReleased keeps its
   zero-the-cell behaviour while editing). Shipped in `bf30bfe`,
   `864b251`, `0b47789`, `3bf71d8`. **Step 6 done.**

7. ✅ **Selection + clipboard.** shift+scroll builds a row-range selection
   on the active column. Bare encoder during selection bulk-edits all
   selected cells (top-as-master snap then dial). `copy` / `cut` / `rand`
   on S1/S2/S3 commit any in-flight bulk edit and run the action; CANCEL
   reverts; UP commits. Shift-held overlay on the default sub bar reveals
   `paste` on S1 when the clipboard is non-empty; paste lands at focus
   head and advances focus head past the pasted region. Type-checked by
   column category. Shipped across `e7aaea3` (Chunk A), `22d7b01`
   (Chunk B + smooth scroll), `bf30bfe` (Chunk C), `864b251` (PASTE).
   **Step 7 done.**

8. ✅ **Access path** — `shift+ENTER` toggle in scope mode, single path.
   Routed via `Channels.toggleSequencerSubView` from
   `xroot/Chain/ScopeView.lua::commitReleased` (shift+ENTER dispatches as
   commitReleased per `xroot/Application.lua:300-305`). Shipped in `ade1f44`.
   **Step 8 done.**

9. ⏳ **Polish + listen test.** _Not started._ Revised estimate
   **~1.5–2.0 weeks** with the expanded backlog below. Items roughly
   in priority order; deferable items at the bottom can slip to v1.1
   if not biting in practice.

   ### UI affordances

   - **(1) L2 cell editor: persistent S3 hint on sub.** Inside the
     modal, S3 has no on-screen label, so the user has no signal that
     S3 does anything. Add a persistent text chip near the S3 ply
     position ("col" or "↔ col", ASCII-safe). Always visible in the
     modal regardless of held state. ~0.05w. File:
     `xroot/Sequencer/CellEditor.lua`.

   - **(2) Always-visible layer toggle on unshifted S3.** Today the
     L1↔L2 toggle is hidden behind shift+S3. Promote it: unshifted S3
     always shows the OTHER layer name. Bidirectional, mirrored
     between L1 and L2 sub bars. ~0.05w. File:
     `xroot/Sequencer/GridView.lua`.

   - **(3) In-takeover BPM control on shift+S2.** BPM is read-only
     inside the takeover today (only editable via admin Settings).
     Add `shift+S2 + encoder` to nudge BPM with fine/coarse/super
     stepping. Applies in both L1 and L2 default views (NOT inside
     selection or modal). Uniform value across all four slots. ~0.15w.

   - **(4) Multi-slot grid view + picker.** GridView hardcodes
     `kSlot = 0`. **Gesture: shift+M2, M3, M4, M5 = slots 0..3**
     (M1 and M6 reserved). Replace constant with `self.slot`; refresh
     updates the "seq{N}.{layer}" title naturally. ~0.2w.

   - **(5) L2 grid expanded-rule preview on shift+S1.** Cells in the
     L2 grid render abbreviated rules with "…" truncation. On L2,
     no modal, no selection: hold shift → S1 shows the full
     pred:action of the cell at `(focusHeadRow, columnCursor)`.
     Conditional: when clipboard non-empty, the same gesture
     previews the clipboard contents (paste-target preview) instead.
     ~0.15w. Reuses `CellEditor.compactPreview()` (factor out into
     a shared `Sequencer/Format.lua` or duplicate).

   - **(6) Coherent / "musical" randomization.** Today RANDOMIZE
     draws from fixed per-column distributions. Add a constrained
     variant that picks only from values already present in the
     column / selection. Placement: **shift+S3 in selection mode =
     coherent random**, unshifted S3 = unconstrained. Extends to
     ACTION_RAND once item 7 lands; may add `ACTION_RAND_COHERENT`
     to keep the Action struct from growing. ~0.2w.

   - **(7) Enable L2 selection (Phase 3-lite).** Lift the Phase 1
     block on L2 selection/copy/cut/paste/random. Selection on L2
     builds a row-range; clipboard distinguishes L1 vs L2 content;
     cross-layer paste refuses. ~0.25w.

   - **(13) L2 col-5 cell truncation tighter than other columns.**
     `fmtL2Cell` (in `xroot/Sequencer/GridView.lua`) truncates at 5
     chars for all columns. Column 5 (stL) sits at x=210..251 and
     the row ruler labels start at x=244 (text glyphs from x=248).
     A "wide" 5-char rule like `A07c:` rendered in proportional
     font 9 can have glyphs extending past x=246, spilling into
     ruler-text territory and producing visual collision against
     "S1" / row digits.
     Fix: pass the column index into the formatter and use a tighter
     truncation (3-4 chars + "...") for col 5 only. OR measure the
     rendered text width via the label's bounding box and re-truncate
     dynamically when it would overflow the column boundary
     (245-px-ish hard limit). Cheaper to just hardcode a smaller cap
     for col 5. ~0.1w.

   - **(14) Out-of-loop cells one level dimmer.** Current
     `kBrightDim = 3` (out-of-loop) vs `kBrightNormal = 6` (in-loop).
     The 3-level gap is subtle; the user's eye doesn't immediately
     pick up the loop boundary at-a-glance. Drop kBrightDim to 1 or
     2 so out-of-loop cells read as visibly secondary. Affects both
     L1 and L2 since `cellBrightness()` is layer-agnostic. ~0.05w.

   - **(15) Cursor box dimmer when not in a "will-mutate" state.**
     Cursor border is `app.GRAY10` in nav mode and `app.WHITE` when
     editing / selecting / marking. The user reports the unfocused
     border is bright enough that distinguishing "I'm just looking
     at this cell" from "I have a live selection here" requires a
     close look. Drop the nav-mode border to `app.GRAY5` (or even
     `app.GRAY3`) so the WHITE active-state border pops as visibly
     different. ~0.05w. File: `xroot/Sequencer/GridView.lua` where
     `self.cursorBox:setBorderColor(active and app.WHITE or app.GRAY10)`.

   - **(16) Mark modal: S3 = "unify" -- snap all columns to the
     marked region.** During the mark modal (1st S2 press through
     2nd-press commit), S3 is currently blank. Use it for a "unify"
     gesture: apply the in-flight `(lo, hi)` marker pair the user is
     defining on the active column to ALL six columns at once. Lets
     a user lock every ply to a shared loop without re-marking each.
     Destructive (overwrites the other columns' existing markers),
     so it gates on a **confirmation toggle in the Sequencer admin
     settings section** (see the "External clock + reset" v2 spec --
     the admin Sequencer page is the natural home for this toggle):
       - toggle ON  -> S3-unify prompts a confirm dialog first
       - toggle OFF -> S3-unify applies immediately
     The bare gesture (immediate-apply) can ship in v1.1 ahead of
     the admin section; the toggle is the v2 refinement. ~0.1w for
     the gesture, +~0.05w for the toggle once the admin page exists.
     File: `xroot/Sequencer/GridView.lua` mark-modal subReleased
     branch + `_commitMark`-adjacent helper to fan the pair across
     columns.

   - **(17) Settings toggle: quicksave restores transport state.**
     Step 3's locked decision force-stops all slots on quicksave
     load -- the running state is NOT serialized. Add an opt-in:
     a Settings entry `quickSaveRestoresSequencerTransport`
     (yes / no, default **no**), sitting alongside the existing
     `quickSaveRestoresRecorder` / `quickSaveRestoresClipboard`
     entries in `xroot/Settings/init.lua` -- no dependency on the
     v2 admin Sequencer page.
     Plumbing needed:
       - Engine: a `SequencerTask::isSlotRunning(slot)` getter
         (`Slot::running` is currently write-only from Lua's POV).
       - `xroot/Sequencer/Persist.lua` serialize: capture per-slot
         running flags into the `data.sequencer` table.
       - `Persist.deserialize`: when the Setting is "yes", call
         `startSlot` for the slots that were saved running instead
         of the unconditional `stopSlot`. When "no" (default),
         keep the current force-stop behaviour.
       - Bench: extend `test_persistence_roundtrip` to cover the
         running-state field.
     Note transport is unified (one S1 toggles all 4) -- a single
     global bool would suffice today, but serializing per-slot
     flags keeps the door open for future per-slot transport
     without a format bump. ~0.15w.

   ### Engine + audio refinement

   - **(8) Audio-thread priority audit for clock stability.**
     Sequencer task at `INT_MAX - 2`. Measure tick jitter under load
     (heavy patches + recording). Bump priority if needed. ~0.15w.

   - **(9) Sample-accurate tick scheduling.** Ticks fire at frame
     boundaries → up to ~2.6 ms jitter at 48 kHz / 128 samples.
     Refactor `processFrame` to split frames at tick boundaries.
     Deferable to v1.1 if not biting. ~0.2w.

   - **(10) Gate-row source disambiguation.** Resolve the gate-row
     TODO at `Sequencer.h:215-220`. v0.1 reads gate-amp from CV1's
     playhead row; pick final semantics (per-column gate? composite?)
     and reconcile PRED_FIRE's slot-level scope. ~0.15w.

   - **(11) gate-len / gate-amp / step-len under load.** Verify
     polymetric patterns don't drift, gate envelopes don't glitch.
     Listen + bench. Deferable to v1.1. ~0.1w.

   - **(12) RNG reproducibility (locked decision #4).** Pick one:
     (a) persist seed in quicksave + Settings toggle; (b) explicit
     re-seed gesture (e.g. shift+HOME outside modals). ~0.1w.

   ### Verification

   - Multi-slot non-interference under playback (all 4 slots ticking
     distinct patterns, no cross-bleed).
   - Quicksave round-trip across firmware reboot with playback
     resuming as authored.
   - Long-run listen test (~30 min).
   - Bench expansion: row-pinned predicate/action, multi-slot
     independence, L2 selection round-trip (post item 7).

   ### Intentionally dropped from polish

   - **L2 cell-editor "delete this cell" gesture.** Covered by
     selection-mode CUT (once L2 selection lands in item 7) and by
     per-cell zero-out in the existing modal flow.

   ### Sub-bar state table — proposed post-Step 9

   | Layer | Selection | Marking | Clipboard | Shift | S1 | S2 | S3 |
   |---|---|---|---|---|---|---|---|
   | L1 | No  | No  | Empty     | No  | start\|stop      | mark | L2 |
   | L1 | No  | No  | Empty     | Yes | —                | BPM  | L2 |
   | L1 | No  | No  | Non-empty | Yes | paste            | BPM  | L2 |
   | L1 | No  | Yes | (any)     | (any) | start\|stop    | end  | — |
   | L1 | Yes | —   | (any)     | No  | copy             | cut  | rand |
   | L1 | Yes | —   | (any)     | Yes | copy             | cut  | coherent rand |
   | L2 | No  | No  | Empty     | No  | start\|stop      | mark | L1 |
   | L2 | No  | No  | Empty     | Yes | rule preview     | BPM  | L1 |
   | L2 | No  | No  | Non-empty | Yes | paste + clip preview | BPM | L1 |
   | L2 | Yes | —   | (any)     | (any) | copy / cut / rand | | |

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
