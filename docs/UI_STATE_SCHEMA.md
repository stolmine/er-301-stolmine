<!-- [stol:ui-planner-state-schema] -->
# ER-301 UI planning domain: the fluent state schema

*The FAR-END goal language of the `ui-planner` cluster
(planning/ui-planning-domain-plan.md §3). It defines a fixed, typed **fluent
vocabulary** describing any reachable UI state, and a deterministic **projection**
from live state to a canonical fluent SET. A **goal** is a PARTIAL assignment of
these fluents (a subset that must hold). The operator library, crawler, and solver
all reason in exactly this vocabulary.*

The 301 UI is deterministic and fully observable: `emu.uiState()`
(`xroot/emu/UIState.lua`) is a perfect state oracle. That is precisely the regime
where **classical planning** dominates and ML is unnecessary — so nothing here
learns. This layer is the vocabulary + a pure normalizer; the reference
implementation is `tools/ui_fluents.py` (stdlib-only), regression-guarded by
`tools/ui_fluents.py --selftest` and `tests/emu/54-fluents-projection.test`.

## Printed form

Every fluent prints as `name(arg,arg,...)` with **no spaces** around the commas or
parens. A **fluent set** is the sorted, de-duplicated list of these strings, so an
identical UI state yields a byte-identical set and a goal is a literal subset. This
is the CONTRACT the operator sibling emits its precondition/effect fluents
against — names and arities below are stable.

Arguments are bare tokens (no quoting). No fluent argument in this domain contains
a `,` or `)` (class names use `.`, unit titles use spaces — both are safe). Cell
**values** are the only numeric argument compared with tolerance; slot and row
indices are integers printed bare.

## The vocabulary

| fluent | arity | count | arg domains |
|---|---|---|---|
| `context(<node>)` | 1 | exactly 1 | ui-map node name, or a raw window class fallback |
| `focused_class(<ClassName>)` | 1 | exactly 1 | a Lua widget/window class |
| `focused_unit(<title>)` | 1 | 0..1 | unit title string |
| `unit_in_chain(<title>)` | 1 | 0..N | unit title string |
| `linked(<a>,<b>)` | 2 | 0..N | `a,b ∈ {1,2,3,4}`, `b=a+1` |
| `slot_control(<slot>,<id>)` | 2 | 0..N | slot `M1..M6`; id = control class **or** on-screen name |
| `column_cursor(<colName>)` | 1 | 0..1 | `cv1 \| cv2 \| g1L \| g2L \| stL \| tr` |
| `cell(<slot>,<col>,<row>,<value>)` | 4 | 0..N | slot int; col name; row int; value float |
| `modal(<flag>)` | 1 | 0..N | a modal-flag name |

### Per-fluent derivation

Each fluent is derived from the projection **bundle** (below): its `uiState` object
(direct from `require('emu.UIState').describe()`) or a supplementary readback field.

- **`context(<node>)`** — *derived from uiState.* The top-window class
  (`uiState.stack[0]`, i.e. `UIState.topClass()`) is mapped to a ui-map node via a
  table that mirrors the `recognize` predicates in `testing-assets/emu/ui-map.toml`:
  `Chain.Root→home`, `Chain.ScopeView→scope`, `Sequencer.GridView→sequencer`,
  `SceneView.Performance→hold`, `Unit.Chooser.Dense→unit_picker_dense`,
  `Unit.Chooser.{Default,Preset}→unit_picker_classic`,
  `SamplePool.Interface→sample_pool`, `QuickSaver→quicksave`, and `Menu` +
  `uiState.context.name` containing `Admin` → `admin`. An unmapped class falls back
  to `context(<TopClass>)` so the (single) context fluent is never missing.
- **`focused_class(<ClassName>)`** — *direct from uiState.* `uiState.focus.class`,
  the encoder-focus leaf (the cursor focus; `UIState.focusClass()`).
- **`focused_unit(<title>)`** — *supplementary.* The focused chain unit's title,
  read via `Channels.getChain(N):getSelection().title` when a Unit is focused.
  (`uiState.selection.sectionName` is the section instance name, not the unit
  title, so the title comes from the readback.)
- **`unit_in_chain(<title>)`** — *supplementary.* Each unit title in the selected
  chain (from a chain walk; see below). A chain arg was intentionally omitted —
  the selected chain is implied — to keep arity low.
- **`linked(<a>,<b>)`** — *supplementary.* From
  `Channels.serialize().links = {link12, link23, link34}` (booleans); a truthy
  `link<a><b>` emits `linked(a,b)` with `a<b` adjacent.
- **`slot_control(<slot>,<id>)`** — *direct from uiState.* For each entry in
  `uiState.controls` (the leaf control under each `M1..M6` column on a
  SpottedStrip), emit `slot_control(slot, class)`, **and** additionally
  `slot_control(slot, name)` when the on-screen name is non-empty and differs from
  the class. Emitting both mirrors `ui_plan.py`'s `control_at`, which accepts either
  a control's name (`V/oct`) or its class (`Unit.ViewControl.Pitch`) for the same
  slot. (A C `int` control name such as the input index `1` arrives as a Lua
  number; it is stringified — `slot_control(M2,1)`.)
- **`column_cursor(<colName>)`** — *supplementary.* The Sequencer.GridView
  `columnCursor` (0..5) mapped through `COLNAMES = [cv1, cv2, g1L, g2L, stL, tr]`
  (the GridView stores the last as `"tr "` with a pad space; the fluent strips it).
  Present only when a `sequencer` block is in the bundle.
- **`cell(<slot>,<col>,<row>,<value>)`** — *supplementary.* Each sequencer L1 cell
  read via `seq:l1Value(slot, col, row)` where `seq = app.AudioThread.getSequencerTask()`.
  The projection reports the **raw** value (e.g. `3.0`); whole numbers keep one
  decimal (`3.0`), fractions strip trailing zeros (`3.25`).
- **`modal(<flag>)`** — *direct from uiState.* Mirrors `uiState.modals` verbatim.
  UIState.lua scans a fixed flag list (`editingL1`, `bpmLatched`, `markingMode`,
  `selectionActive`, `favoritesEditMode`) across the context/window/focus chain.
  **Known quirk (mirrored, not fixed):** on `Sequencer.GridView`, `markingMode`
  reads truthy even when idle, because its idle value is the string `"idle"` (Lua
  truthy) and UIState tests `obj[flag]` for presence. We faithfully reflect this;
  goal-subset semantics mean the extra `modal(markingMode)` never blocks a goal
  that does not mention it.

### uiState-direct vs supplementary

| fluent | source |
|---|---|
| `context`, `focused_class`, `slot_control`, `modal` | **directly** in the base `uiState` JSON |
| `linked`, `focused_unit`, `unit_in_chain` | supplementary `lua` readback |
| `column_cursor`, `cell` | supplementary `lua` readback (sequencer block) |

## The projection bundle (extended state vs supplementary readback)

`cell`, `linked`, `column_cursor`, and `focused_unit` are **not** in the base
uiState JSON. Rather than extend `xroot/emu/UIState.lua` (shared Lua we must not
modify), the projection consumes a small **bundle** the caller assembles from a
handful of separate `lua` control-command queries. This is the deliberate design
choice: **supplementary readback, not an extended uiState**. It keeps UIState.lua
untouched, keeps each `lua` reply small (the emu caps a control reply near ~512
bytes, so a single monolithic dump is not even possible), and localizes the extra
data contract here.

```jsonc
{
  "uiState": { ...require('emu.UIState').describe()... },   // REQUIRED
  "links":   {"link12": false, "link23": false, "link34": false},
  "focused_unit": "<title>",                 // when a Unit is focused
  "units_in_chain": ["<title>", ...],
  "sequencer": {                             // present iff on Sequencer.GridView
    "slot": 0,
    "columnCursor": 0,
    "cells": [["cv1", 0, 3.0], ["cv1", 1, 3.0], ...]   // [colName, row, value]
  }
}
```

Only `uiState` is required; a bare `{"uiState": ...}` still projects
`context`/`focused_class`/`slot_control`/`modal`.

### Assembling the bundle (the `lua` one-liners)

```
uiState        : lua return require('emu.UIState').describe()   -- (as JSON via .json())
links          : lua local l=require('Channels').serialize().links; return {link12=l.link12,link23=l.link23,link34=l.link34}
focused_unit   : lua local s=require('Channels').getChain(1):getSelection(); return s and s.title or nil
units_in_chain : lua local c,t=require('Channels').getChain(1),{}; for i=1,c:length() do t[i]=c:getView('expanded'):getSection(i)... end  -- chain walk
sequencer.slot         : lua return require('Application').getVisibleContext():top().slot
sequencer.columnCursor : lua return require('Application').getVisibleContext():top().columnCursor
sequencer.cells        : lua local s=app.AudioThread.getSequencerTask(); ... s:l1Value(slot,col,row) per (col,row) of interest
```

The reference host-side normalizer is `tools/ui_fluents.py`:

```python
from tools import ui_fluents
fluents = ui_fluents.project(bundle)            # sorted list[str]
ok      = ui_fluents.satisfies(fluents, goal)   # goal ⊆ state (cells within tol)
```

`satisfies(state, goal)` treats every non-`cell` fluent as an exact string
membership test and matches `cell` fluents on `(slot,col,row)` with the value
compared within `CELL_TOL = 1e-6`. `parse_goal(text)` accepts either a JSON array
of fluent strings or a newline/`;`-separated list (with `#` comments).

## Worked example states

### 1. Boot — `Chain.Root` ("OUT1 edit")

Captured live from the hermetic fixture (`pickerStyle=dense`). Projected set:

```
context(home)
focused_class(Chain.Root)
slot_control(M1,ChainTitleControl)
slot_control(M2,1)
slot_control(M2,InputControl)
slot_control(M3,EmptySection.EmptyControl)
slot_control(M4,EmptySection.EmptyControl)
slot_control(M5,EmptySection.EmptyControl)
slot_control(M6,MonitorControl)
```

No `modal`, `cell`, `linked`, `column_cursor`, or `focused_unit` (the cursor sits
on the `HeaderSection`, not a Unit). `slot_control(M2,1)` is the input control's
numeric on-screen name.

### 2. Sequencer, cv1 rows 0..5 = 3.0 ("C3")

Reached by `mode down` → `Chain.ScopeView`, then SHIFT+ENTER → `Sequencer.GridView`,
then `MAIN1` (focuses cv1, `columnCursor=0`), then `seq:setL1(0,0,r,3.0)` for
`r=0..5`. Projected set includes:

```
cell(0,cv1,0,3.0)
cell(0,cv1,1,3.0)
cell(0,cv1,2,3.0)
cell(0,cv1,3,3.0)
cell(0,cv1,4,3.0)
cell(0,cv1,5,3.0)
column_cursor(cv1)
context(sequencer)
focused_class(Sequencer.GridView)
modal(editingL1)
modal(markingMode)
```

(`modal(editingL1)` because `MAIN1` on the focused column enters inline L1 edit;
`modal(markingMode)` per the idle-string quirk above.)

**The C3 goal** is the partial set

```
context(sequencer)
column_cursor(cv1)
cell(0,cv1,0,3.0) … cell(0,cv1,5,3.0)
```

and `satisfies(state_2, C3_goal)` is **True** — proven in
`tools/ui_fluents.py --selftest` and, at the readback level, in
`tests/emu/54-fluents-projection.test`.

### 3. Stereo-linked boot (partial)

With `Channels.serialize().links.link12 == true`, the boot set additionally
contains `linked(1,2)`. A goal of `{linked(1,2)}` is then satisfied.

## What the operator sibling must mirror

The operator library (`ui-planner-operators`) emits precondition/effect fluents
against **this exact set** — same names, arities, and printed form:

- `context/1`, `focused_class/1`, `focused_unit/1`, `unit_in_chain/1`,
  `linked/2` (a<b adjacent), `slot_control/2` (class **and** name variants both
  present in a state — emit/expect both), `column_cursor/1` (`COLNAMES` tokens,
  `tr` not `"tr "`), `cell/4` (slot,col,row,value; value numeric with tolerance),
  `modal/1` (verbatim uiState.modals, including the `markingMode` idle quirk on the
  grid).
- Node names for `context/1` come from `testing-assets/emu/ui-map.toml`
  (`unit_picker_dense`, `sample_pool`, `quicksave`, …), verbatim. (Reconciled
  2026-07-10: the operator library uses these raw map names too, NOT the `picker`
  shorthand once used in prose — so a nav operator's `context()` effect chains
  into another operator's precondition.)
- **`adjacent/2`** is a *static domain predicate*, not a state fluent: `adjacent(a,b)`
  (channels a,b are neighbours, a<b) is always true/false by the fixed channel
  topology, so it appears ONLY in operator preconditions (e.g. `link`), never in a
  projected state set. `tools/ui_fluents.py` does not emit it; the operator library
  and the future solver treat it as an axiom.

## Provenance

- Vocabulary + projection: `tools/ui_fluents.py` (`[stol:ui-planner-state-schema]`).
- Live-input proof: `tests/emu/54-fluents-projection.test`.
- Projection/satisfaction proof: `tools/ui_fluents.py --selftest`.
- Column names mirror `xroot/Sequencer/GridView.lua` `kColNames`; context mapping
  mirrors `testing-assets/emu/ui-map.toml`; the base state fields come from
  `xroot/emu/UIState.lua` `describe()` (read-only).
