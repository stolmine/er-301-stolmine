# Sequencer modal sweep — test results + follow-up punch list

Bench-validated 2026-06-09 by walking the full 40-row test matrix.
Annotated results in `sequencer-modal-sweep-test-matrix-results.csv`
(blank template at `sequencer-modal-sweep-test-matrix.csv`).

Status: sweep landed at `f76a666` + BPM-latch S2 fix at `4df6781`.
Hardware build: `release/am335x/er-301-v0.7.0-stolmine.9.4.0.26.zip`.

## Pass summary

The 8 collisions the sweep targeted all pass. The modal-mutual-
exclusion invariant holds: any sequence of "enter modal A, then enter
modal B" lands cleanly in B with A committed/exited, no stale visual
cursors, encoder routing always matches the visible modal.

Confirmed in bench:
- A1-A5: BPM latch entry from every prior state. Selection wins when
  active (correct: selectionActive's S-bar steals subDisplay so
  shift+S2 entry is implicitly blocked). Mark wins when active
  (correct: shift is a no-op during marking).
- B1-B5: BPM latch exit. Bare S2 exits cleanly; bare S2 + shift+S2
  both work; release-timing edge case (shift released before S2)
  also clean via transient flag.
- C2-C5: L1 edit entry from selection / mark / BPM / advance-row.
  All clean.
- D2-D4: L2 CellEditor modal opens cleanly from selection / mark /
  BPM latch.
- E1, E3, E4: Mark entry — selection / BPM cases implicitly blocked
  by S-bar reassignment + shift-no-op, exactly as intended.
- F1-F3, F5, F6: Column switch from every state.
- G1-G3: M-tap on current column (edit gesture).
- H1-H8: Sanity encoder routing.

## New findings (6 items, sorted by surface area)

### 1. F4 — Same-column M-tap during selection lands in edit mode

**Repro**: extend a selection on column 0, then tap M1 (current
column).

**Expected** (per user direction 2026-06-09): "nav to end cell in
selection." Selection is a transient modal entered to perform an
action, then auto-exits. Tapping the column's M-key should snap
focusHead to `selectionEnd` and drop selection.

**Currently**: forwards to `enterReleased(false)` (per the recent
"M-tap on focused col = edit" feature), which enters edit mode.
Loses the user's selection context entirely.

**Fix surface**: `mainReleased` in `xroot/Sequencer/GridView.lua`,
when `newCol == columnCursor`, branch on `selectionActive` BEFORE
forwarding to enterReleased. Snap focusHead to selectionEnd, drop
selection, return.

**~10 lines.**

### 2. D1 — L1→L2 layer switch while editingL1 leaves null state

**Repro**: ENTER on L1 to enter editingL1, switch layer to L2.

**Currently**: editor focus on the L2 cell but no CellEditor modal
open. A null state — user can exit but it's confusing.

**Expected**: layer switch drops `editingL1`. The L2 layer doesn't
have an inline edit concept (it uses the modal), so carrying the
edit flag across is meaningless.

**Fix surface**: in the layer-toggle gesture, call
`_commitOtherModalsBefore(nil)` or clear `editingL1` explicitly.

**~5 lines.**

### 3. H6 — Add BPM edit caret indicator

When `bpmLatched`, no visual element next to the BPM digits in the
sub display signals "this is the live encoder target." The only
cue is the sub-bar label.

**Fix surface**: add a DrawingInstructions caret / underline /
inverse-block next to the BPM line, shown when `bpmLatched`. Hide
otherwise.

**~15 lines** (a Drawing element + show/hide tied to refresh).

### 4. H8 — Bulk edit should respect coarse/fine encoder state

**Repro**: extend a selection on a CV column, twist encoder to bulk-
edit values.

**Currently**: step is fixed integer (or super-step with shift).
Coarse/fine encoder state is ignored. Users can only nudge by whole
units even when fine mode is engaged.

**Expected**: bulk-edit branch reads `self.encoderState` and picks
fine vs coarse step the same way the single-cell editingL1 branch
does.

**Fix surface**: encoder() bulk-edit branch around line 1620. Read
encoderState (or whatever the L1 path uses) and pass through to
`stepForColumn`.

**~15 lines.**

### 5. H4 — Use encoder coarse/fine LEDs instead of sub-display labels

User observation: the encoder hardware has coarse/fine indicator
LEDs around the dial. For editingL1 and bpmLatched modes, those
LEDs should reflect state instead of (or in addition to) the
sub-display text label. Frees real estate + more glance-able.

**Needs**: identify the LED API surface in `od/`. Probably an
`app.Encoder.setLED(...)` or similar.

**Surface unknown until API located**.

### 6. C1 + E2 — Architectural: edit as terminal modal + S-key rebind

**User's bigger thought**: while in editingL1, the S-keys retain
their nav-mode meanings (S1 bksp, S2 cursor, S3 space -- wait those
are keyboard. For sequencer S1/S2/S3 are transport / mark / unify).
The cross-modal slipping that the sweep cleaned up could be more
cleanly prevented by making editingL1 a **terminal modal**: while
editing, the S-keys do edit-specific actions, not modal-entry
gestures.

**Proposed bindings while editingL1**:
- S1 = duplicate cell value from row above
- S2 = ? (TBD, possibly blank)
- S3 = randomize cell using the column-type-aware random pool

**Effect**: editing becomes a focused mode the user enters to work
on cells, exits via UP / CANCEL / column-switch. No accidental
escape into mark mode or BPM latch because S-keys can't trigger
those while editing.

**Trade-off**: asymmetric vs current "edit can be entered from any
modal." User noted: "not sure we care about symmetry here. will
have to think on this."

**This is a design decision**, not a surgical fix. Should be locked
before building.

Open Qs:
- S2 binding (blank ok? clipboard paste? next-row? something else?)
- Does shift+S do anything different during edit?
- Applies only to L1 inline edit, or also to the L2 CellEditor modal
  (which has its own S-key bindings already)?
- What about the encoder dial gestures while editing? Currently
  encoderState is implicit -- coarse/fine via dialPressed.

## Recommended ship order

The first 4 items are surgical batches that can ride a single polish
branch (~50 lines total, no design debate). Items 5 + 6 want
separate treatment.

| Order | Item | Why now |
|---|---|---|
| 1 | F4 selection-nav fix | Blocks correct selection workflow |
| 2 | D1 drop editingL1 on layer switch | Bug, clean fix |
| 3 | H6 BPM caret | Small UX, no dependency |
| 4 | H8 bulk-edit coarse/fine | Small UX, no dependency |
| 5 | H4 encoder LEDs | Pending API surface check |
| 6 | C1 + E2 terminal-edit | Design decision first |

Bench gate between batch 1-4 and items 5-6: dev-build, hardware-
bench, then design conversation for 6.

## Where things live

- Test matrix template (40 rows, no results):
  `docs/planning/sequencer-modal-sweep-test-matrix.csv`
- Test matrix with bench annotations (this session's pass):
  `docs/planning/sequencer-modal-sweep-test-matrix-results.csv`
- Sweep commit (helper + 4 entry-point applications):
  `f76a666` "sequencer modal-mutual-exclusion sweep: single encoder owner"
- BPM latch S2 fix:
  `4df6781` "sequencer: BPM latch exit consumes matching S2 release via transient flag"
- This follow-up doc:
  `docs/planning/sequencer-modal-sweep-followups.md`
