# Getting Started

A cursory tour of three significant features the stolmine fork adds on top of stock
ER-301 firmware: the **dense unit picker**, the **sequencers**, and
**scene mode**. Each section is just enough to get you moving; pointers
to the full reference docs are at the end of each.

Throughout: `M1..M6` are the six main-display softkeys, `S1..S3` are the
sub-display softkeys, **encoder** is the main knob, **dial** is the coarse/fine
button under it, and `shift` is the lower-right modifier. The physical
three-position toggle selects **edit / scope / hold** contexts.

---

## 1. Dense unit picker

A faster way to find and insert units. Instead of the classic
rectangle-per-unit grid, you get a 2-column scrolling list (10 units
on screen), an alphabet ribbon for jump-to-letter, several sort orders,
and type filtering, plus favorites and a hide list, both of which
persist across boots.

Currently this is the default picker. Turn it on in **admin menu → Settings → Unit
Picker → `pickerStyle = dense`**. The classic picker stays available
under `original`, so nothing is lost.

### Try it

1. Insert or replace a unit anywhere in a chain — the picker opens
   automatically. It starts on the **recents** sort, no filters.
   (you can pick a default sort method in system settings)
2. **Turn the encoder** to move the row cursor up and down the list.
   The cursor box highlights a whole row (both columns).
3. **Press `M1`** to insert the unit in the **left** column, **`M4`**
   for the **right** column. (`ENTER` is a one-handed alias for `M1`.)
   (you can also use `S1` and `S3` to pick left or right, `ENTER` will pick the left)

That is the whole core loop: scroll, pick. Everything else is narrowing.

### Narrowing the list

| Gesture | Effect |
|---|---|
| `shift` + encoder | Move the **alphabet ribbon** to jump to a letter (stops at the ends, no wrap) |
| `M2` / `shift`+`M2` | Cycle **sort** forward / back: recents · alpha · type · package · keyword · favorites |
| `M3` / `shift`+`M3` | Cycle the **type filter** forward / back through unit classes; cycles back to *off* |
| `HOME` | Snap cursor to the top of the current view |
| `shift`+`HOME` | Full reset: ribbon off, type filter off, sort back to your default |
| `CANCEL` / `UP` | Close the picker without inserting |

### Favorites and hiding

- **`M6`** enters **favorite-edit** mode: `M1`/`M4` tag the left/right
  unit as a favorite. Press `M6` again to leave. Favorites can be
  pinned to the top and sorted first.
- **`M5`** enters **hide-edit** mode: `M1`/`M4` hide the left/right
  unit so it stops cluttering the list (there is a "show all" to undo).
  Press `M5` again to leave.

Both lists persist across restarts. The same Unit Picker settings page
has toggles for section dividers and for pinning favorites/recents to
the top.

---

## 2. Sequencers

Four concurrent sequencers, each with two CV lanes, two gates, an
independent step-length column, and a transpose column — plus a second
"rules" layer (a simple `IF condition : THEN action` per cell). The
sequencers are a firmware service, not a chainable unit; their outputs
appear in the source picker as `seqN.cv1`, `seqN.cv2`, `seqN.gate1`,
`seqN.gate2` (with `N` = 1..4).

### Try it

1. Put a channel into **scope** mode (physical toggle), then press
   **`shift`+`ENTER`**. The takeover grid opens on the current slot.
2. The grid is 6 columns (`cv1 cv2 g1L g2L stL tr`) and 6 visible rows.
   **Turn the encoder** to scroll the focus head; **`M1..M6`** jump the
   column cursor.
3. On a `cv1` cell, press **`ENTER`** to start editing. Turn the encoder
   to set a pitch; press **`dial`** to toggle fine/coarse step size.
   Press **`ENTER`** again to commit and drop to the next row (fast
   column entry). `UP` commits and exits; `CANCEL` exits without saving.
4. Jump to the `g1L` column (`M3`) and author gate lengths the same way
   (0 = no gate; the top value is a `TIE` that holds across the step).
5. Press **`S1`** to start/stop all four slots together.
6. Patch the result: anywhere you choose a source, pick `seq1.cv1` and
   `seq1.gate1` into a unit's pitch and trigger inputs.
7. **`shift`+`ENTER`** exits the takeover back to scope.

### Worth knowing early

- **`shift`+`M2..M5`** switch between slots 1..4 (all share one tempo).
- **`shift`+encoder** while scrolling builds a row-range **selection**;
  the sub bar then offers `copy` / `cut` / `rand` (per-column musical
  randomization).
- **`S2`** opens the **mark** modal to set the per-column loop region.
- **`shift`+`S2`** latches a **BPM** fader onto the encoder.
- **`UP`** toggles between layer **L1** (the values) and **L2** (the
  rules). On an L2 cell, `ENTER` opens the expression editor.

The L2 rules layer is where this gets deep (conditional retriggers,
playhead jumps, cross-column math, probability). It has its own full
treatment.

➜ **Full reference:** [`SEQUENCER.md`](SEQUENCER.md) — every column type,
nudge size, predicate/action, clipboard state, and persistence detail.

---

## 3. Scene mode

Scene mode replaces the old hold-mode pinning workflow with an
Octatrack-style approach: capture **scenes** (snapshots of your patch's
control values) and **morph** smoothly between two of them with a
crossfader — by hand or driven by CV.

You author scenes the same way you edit normally: any knob you touch
while editing a scene is captured as that scene's *change from base*.
There is no pin-every-control tax and no modulation matrix to fill in.

Enable it in **Settings → Scenes → `sceneMode = on`**. With it off, the
hold context opens the legacy PinView instead.

### Enter and exit

Flip the physical toggle to **hold**. With scene mode on, this opens the
**Performance view** and engages the crossfader (it snapshots every
morphable control's current value as the base). Flip back to **edit**
to leave; your base values are intact.

### The Performance view

Left to right across the softkeys:

- **`M1` — Morph.** The crossfader. With it focused, the encoder sweeps
  the blend between the **A** and **B** scenes. `S2`/`S3` focus its gain
  and bias readouts; **`S1`** dives into a sub-chain where you can insert
  a CV source (LFO, sequencer, envelope) to drive the morph automatically.
- **`M2` / `M3` — A and B selectors.** Each picks which scene sits at
  that end of the crossfader and can itself be CV-driven (`S1` dives a
  per-role CV branch; `S2`/`S3` set its gain/bias). Wire an LFO here and
  the A or B endpoint sweeps through your scene bank on its own.
- **`M4..M6`+ — Scene slots**, one per scene (up to 16). The cursor
  moves here as you turn the encoder past the selectors. A trailing
  **`+`** slot appears when there's room — **tap its `M`** to create a
  new scene.

### Author and perform

With a scene slot under the cursor, the sub bar gives you:

| Key | Default | With `shift` |
|---|---|---|
| `S1` | Assign this scene to endpoint **A** | **Copy** (duplicate) the scene |
| `S2` | Assign this scene to endpoint **B** | **Rename** the scene |
| `S3` | **Edit** (enter authoring) | **Delete** the scene (confirm prompt) |

A typical pass:

1. **Create** a couple of scenes by tapping the `+` slot.
2. Cursor to a scene, press **`S3` edit**. You're now in the normal edit
   surface (subtitle shows which scene). Turn any controls you want this
   scene to move — each is captured as a delta. `UP`/`CANCEL`, or flip
   the toggle, to return to Performance.
3. Repeat for the other scene(s).
4. Cursor to one scene and **`S1`** to make it **A**; cursor to another
   and **`S2`** to make it **B**.
5. Focus **`M1`** and turn the encoder to **morph** between A and B in
   real time. Optionally dive `M1`/`M2`/`M3` `S1` to hand the sweep to CV.

### Housekeeping

- Scenes persist with the patch (quicksave).
- **Admin menu → Reset Scene Mode** clears all scenes and CV branches on
  every channel and restores defaults (confirmation prompt unless you've
  turned it off under Settings → Confirmations).

➜ **Design background:** see `docs/planning/hold-mode-scenes-ux-spec.md`
and `docs/planning/hold_mode_refactor.md` for the model and rationale.

---

## Where to go next

- **Sequencers, in full:** [`SEQUENCER.md`](SEQUENCER.md)
- **Project knowledge / build & deploy:** [`docs/KNOWLEDGE.md`](docs/KNOWLEDGE.md)
- **Design docs for all of the above:** [`docs/planning/`](docs/planning/)
