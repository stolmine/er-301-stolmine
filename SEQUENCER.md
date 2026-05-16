# Sequencer

4 concurrent sequencers, each carrying 2 channels of CV and gate,
independent step length column, and transposition. Each sequencer
also includes a second layer, which exposes a simple IF > THEN
framework where actions can be called via conditionals on individual cells as the
playhead passes over them. You can find sequencers by entering scope mode
and hitting `shift+ENTER`.

## Quick start

1. From the chain scope view, press `shift+ENTER`. The takeover grid
   opens on the currently-selected slot.
2. The grid shows 6 columns and 6 visible rows. Top row is the column
   header; cells below show L1 values.
3. Encoder scrolls the focus head; `M1..M6` jump the column cursor.
4. Pressing `ENTER` while focused on a cell has different effects in L1 and L2. In L1, this enters edit mode where the encoder adjusts the value in-step. In L2 it opens the expression editor for the given cell.
5. `S1` starts/stops all slots together. The slot's CV and gates show
   up on the chain picker as `seqN.cv1`, `seqN.cv2`, `seqN.gate1`,
   `seqN.gate2` (slot `N` is 1..4).
6. `shift+ENTER` again exits the takeover.

## Column layout

Each slot has 6 columns. Four are routed to the chain picker; two are
internal (used by the engine only).

| col | symbol | type | role | picker output |
|---|---|---|---|---|
| 0 | `cv1` | CV (V/oct) | primary pitch lane, transpose pre-applied | `seqN.cv1` |
| 1 | `cv2` | CV (raw volts) | secondary modulator | `seqN.cv2` |
| 2 | `g1L` | gate length (beats) | gate 1 length | `seqN.gate1` |
| 3 | `g2L` | gate length (beats) | gate 2 length | `seqN.gate2` |
| 4 | `stL` | step length (beats) | per-tick spacing | internal |
| 5 | `tr`  | transpose (semitones) | shifts cv1 only | internal |

Gate amplitude is constant 1.0; gate columns store length only. A
gate-len cell value of 0 means "mute" (no gate). A value of
`4.0` (top of the dial range) is the `TIE` sentinel: gate held across
the full step. Random rolls on gate-len exclude `4.0` so TIE is only
ever authored deliberately.

Step-length is in beats (1.0 = quarter note); displayed as integer
ticks at the locked 4 PPQN base (1 tick = 1/16 note = 0.25 beats).
Floor enforced at 0.0625 beats.

Transpose is integer semitones in `[-60, +60]`. The engine pre-applies
it to cv1's sample-and-hold each tick: `heldCV1 = cv1Raw + tr / 12`.
The grid still displays the raw cv1 cell value (authoring stays clear);
the transposed value is what the cv1 audio buffer carries.

## Navigation

| Button | Behavior (grid view) |
|---|---|
| `ENTER` | Enters edit mode/modal on given cell |
| Encoder | Scroll focus head (one row per click) |
| `shift+Encoder` | Build a row-range selection on the focused column |
| `M1..M6` | Jump column cursor to column 1..6 |
| `shift+M2..M5` | Switch to slot 1..4 |
| `HOME` | Jump focus to row 0 |
| `UP` | Unselect, leave modal, etc |
| `S2` (default sub bar) | mark start/end |
| `S3` (default sub bar) | toggle layer |
| `shift+ENTER` | Toggle takeover on/off |

Focus-head and column-cursor together define the **active cell**, drawn
as a thin box. `ENTER` starts the cell-edit modal for the given position.

## Editing L1 cells

`ENTER` on an L1 cell enters inline-edit mode: the encoder nudges the
value, M-keys still jump columns (committing the in-flight edit and
focusing the new cell), `ENTER` again moves down a cell and stays in edit mode for convenience. 
Up exits edit mode and commits value, cancel exits edit mode without committing.

Per-column nudge sizes:

| column | fine | coarse | super-fine | super-coarse |
|---|---|---|---|---|
| cv1 (V/oct) | 1 semi | 1 oct | 1 cent | 12 oct |
| cv2 (volts) | 0.1 V | 1 V | 0.01 V | 10 V |
| g1L / g2L (beats) | 1/16 | 1/4 | 1/64 | 1 beat |
| stL (ticks) | 1 tick | 4 ticks | 1 tick | 16 ticks |
| tr (semitones) | 1 semi | 1 oct | 1 semi | 2 oct |

`dial` toggles fine/coarse. `shift+Encoder` while editing picks the
"super" variant.

`shift+HOME` inside an L1 cell editor zeros the focused cell.

## L2 grammar (predicate : action)

L2 cells encode rules that fire when the host column's playhead lands
on the cell's row. The cell-edit modal exposes 6 slots:

| slot | field | type |
|---|---|---|
| M1 | predicate's column-A reference | cell-ref (column letter + optional row) |
| M2 | predicate operator | choice |
| M3 | predicate operand | number |
| M4 | action target column | cell-ref |
| M5 | action operator | choice |
| M6 | action operand | number |

### Predicates (IF condition is met...)

| symbol | name | when it fires |
|---|---|---|
| `%N` | modulo | every N-th pass over the host column |
| `=N` | equals | colA's cell value == N |
| `>N` | greater than | colA > N |
| `<N` | less than | colA < N |
| `?N` | probability | true with N% probability per tick |
| `~N` | approx equals | colA approximately == N (within 0.05)|
| `!`  | any gate fires | gate1 OR gate2 produced an edge this tick |
| `!1` | gate1 fires | gate1 produced an edge this tick |
| `!2` | gate2 fires | gate2 produced an edge this tick |
| `c`  | changed | colA's playhead-row value changed since last tick |

### Actions (THEN perform this action on target)

| symbol | name | effect on target cell |
|---|---|---|
| `+N` | add | `target += N` |
| `-N` | subtract | `target -= N` |
| `=N` | set | `target = N` |
| `*N` | multiply | `target *= N` |
| `/N` | divide | `target /= N` (no-op if N == 0) |
| `!1` | retrigger gate1 | re-arms gate1 envelope for current g1L beats |
| `!2` | retrigger gate2 | re-arms gate2 envelope for current g2L beats |
| `?`  | randomize | per-column random value (see Random per column) |
| `M`  | mute | `target = 0` |
| `j`  | jump host | host column's playhead jumps to row N at next tick |
| `J`  | jump all | every column's playhead jumps to row N at next tick |
| `.`  | jump self | this column's playhead jumps to row N at next tick |

Target column defaults to host (`-1`); cell-ref's row pin is optional
(blank = "use that column's current playhead row"; explicit row =
read/write that exact cell).

Example rules:
- `%4 : B+1`: every 4th pass over the host column, add 1 to cv2's
  current cell.
- `!1 : !2`: when gate1 fires, also retrigger gate2 (cross-trigger).
- `~0 : M`: when colA's value is approximately zero, mute the target.
- `=8 : *0`: at step 8 on the host, jump every column's playhead to
  row 0.

## Selection, clipboard, transport

| state | S1 | S2 | S3 |
|---|---|---|---|
| Default, L1 | `start/stop` | `mark` | `L2` (toggle) |
| Default, L2 | `start/stop` | `mark` | `L1` (toggle) |
| `shift` held, default | (paste if clipboard) | `BPM` latch | `clr` cell |
| `shift+S2` held / latched | encoder routes to BPM | -- | -- |
| Selection active | `copy` | `cut` | `rand` |
| Mark modal | `start/stop` | `end` (commit) | `unify` (all cols will get same start/end as proposed) |

`hold shift+S2` latches the BPM fader: tap S2 to release. Fine = 0.1 BPM
per tick, coarse = 1.0 BPM per tick.

`shift+S3` (default sub bar, no selection, no marking) clears the
focused cell: L1 writes 0.0; L2 removes the rule (sets `present =
false`, distinct from authoring a no-op rule).

Selection is built by holding `shift` while scrolling: the focus head
becomes the moving end, the anchor stays where shift was first
pressed. `copy`, `cut`, and `rand` operate on the whole row range.
Paste lands at the focus head and extends past the pasted region.
L1 and L2 clipboards are distinct (cross-layer paste refuses).

Mark modal: press `S2` to plant the first marker at the focus head;
encoder + `HOME` live-update the second marker; press `S2` again to
commit the loop region as `(min, max)` of the two markers. `S3 unify`
applies the in-flight marker pair to all 6 columns at once (gated by
the `unifyConfirm` Setting for safety).

## Transport, BPM, persistence

- `S1` starts or stops all 4 slots together. Transport state is
  unified across slots.
- Global BPM is a single value applied to all slots; latched edit via
  `shift+S2`. Persists in System Settings.
- Quicksave round-trips every column's length, markers, L1 cell values,
  and L2 rules. Schema is versioned (`schemaVersion = 2`); v0.1
  quicksaves migrate automatically on load.
- System Settings (under the `Sequencer` subheading):
  - `unifyConfirm` (yes/no, default yes): prompts before mark-modal
    Unify fans markers across all columns.
  - `quickSaveRestoresSequencerTransport` (yes/no, default no): when
    yes, slots resume their saved running state on quicksave load.

## Random distributions per column

The `RANDOMIZE` selection-action and L2's `?` action draw from
musically-sensible per-column distributions:

| column | distribution |
|---|---|
| cv1 (V/oct) | random semitone in -60..+60 (5 octaves either way) |
| cv2 (volts) | -5..+5 V, 0.1 V resolution |
| g1L / g2L | `{1/16, 1/8, 1/4, 1/2, 1, 2}` beats (TIE excluded) |
| stL | `{1, 2, 4, 8, 16, 32}` ticks * 0.25 beats |
| tr (semitones) | `{0, 0, 0, 0, 0, -12, -7, -5, 0, 5, 7, 12}` (zero-weighted pentatonic + octaves) |

## Slot output mapping

Each slot exposes exactly 4 patchable outputs in the chain picker:

| picker name | what it carries |
|---|---|
| `seqN.cv1` | cv1 raw cell value + transpose / 12 (V/oct ready) |
| `seqN.cv2` | cv2 raw cell value (unipolar voltage, 0..10 V scaling per ER-301 convention) |
| `seqN.gate1` | gate1 envelope (amp 1.0 when armed, 0 otherwise) |
| `seqN.gate2` | gate2 envelope (amp 1.0 when armed, 0 otherwise) |

`step-len` and `transpose` are internal (sequencer-only); not patchable.

## Tips

- A short gate-len authored on a row whose step-len is much larger
  produces a clean transient (e.g. `g1L = 0.0625` on `stL = 1` = short
  trigger every quarter note).
- TIE on consecutive rows extends the held gate across the whole run.
  TIE on a row with no prior gate starts a fresh full-step gate (TIE
  in isolation = full-width gate).
- Use the `tr` column for pentatonic / octave melodic shape without
  retyping cv1: hold cv1 to a single note, then animate `tr` with the
  biased random palette.
- Cross-trigger one gate from the other in L2: `!1 : !2` (when gate1
  fires, also trigger gate2). Lets one column define the rhythmic
  structure of another.
- `shift+M2..M5` switches slot; all four slots run on the same tick
  base (global BPM) so cross-slot polymeter is just per-column length
  manipulation across slots.

## Limits

- 4 slots, 6 columns each, 64 rows per column maximum (logical loop
  length is per-column, 1 to 64 rows).
- L2 cells store one predicate + one action per row. Compound
  predicates (AND/OR/NOT) are out of scope for v0.1/v2.
- External clock-in is not wired up; BPM is internal only.
- A live playhead-scrub gesture is not exposed.
- The cell editor's `@[a, b]` step-range predicate is reserved but not
  yet authorable (engine has `PRED_STEP_RANGE`, no operand2 in the
  cell editor yet).
