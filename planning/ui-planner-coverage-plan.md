# UI planning domain — coverage expansion to close the 8 uncovered operators + 3 fluent types

*Goal: raise the goal-corpus coverage from 12/20 operators + 6/9 fluent-types toward
full, by addressing the ACTUAL root cause of each gap (they are four distinct causes,
not one). Spec for the `ui-planner-cov-*` ledger cluster. Extends the completed UI
planning-domain facility (planning/ui-planning-domain-plan.md). All conventional, no
ML — same regime.*

## 0. The exact gaps (testing-assets/emu/goal-coverage.txt)

**8 uncovered operators, 3 uncovered fluent types**, which sort into FOUR causes:

| # | uncovered | cause |
|---|---|---|
| A | nav_admin_to_home, nav_scope_to_home, nav_quicksave_to_home, nav_unit_picker_dense_to_home, nav_sample_pool_to_admin | **boot-start artifact** — every goal starts at `context(home)`, so A* never needs to route BACK to home (4 return-navs) or INDIRECTLY to admin via sample_pool (already 1 op from home). Not a modeling gap; a start-state limitation. |
| B | expand, collapse  (+ fluent type `slot_control`) | **prose effect** — the operator generator emits expand/collapse's effect as the string "slot_control map -> u.views.*" instead of concrete `slot_control(Mi,ctrl)` fluents, so no goal can target them. `slot_control` is produced ONLY by these two. |
| C | focus_unit  (+ fluent type `focused_class`) | **no multi-unit start** — `focused_unit(u)` is auto-produced by `insert`; from a boot (empty) chain no OTHER unit pre-exists to re-focus. `focused_class` is not emitted as an effect by any modeled operator. |
| D | (fluent type `modal`) | **transient** — the only modeled modal is `set_cell`'s `modal(editingL1)`, stripped as non-durable. Some modals ARE durable end-states (favorites-edit, mark, selection); those need new operators. `editingL1` itself is legitimately transient. |

## 1. Mechanisms (one per cause)

### A. Non-boot start states (`ui-planner-cov-starts`)
The solver already accepts `--from <fluent state>`; extend the CORPUS + `--run` so a
goal can declare a start context and the executor auto-routes to it before planning:
- Goal-file directive `# start: context(<node>)` (default = boot/home).
- `ui_goals.py --run`: boot (home) → plan+drive a SETUP route home→start (reusing the
  solver) → then plan+execute the goal FROM the start state → assert. The setup route
  is not part of the measured plan; only the goal's plan counts toward coverage.
- Add corpus goals: `home-from-admin` (start admin, goal context(home) → exercises
  `nav_admin_to_home`), `home-from-scope`, `home-from-quicksave`,
  `home-from-picker`, and `admin-via-sample-pool` (start sample_pool, goal
  context(admin) → `nav_sample_pool_to_admin`). Closes all 5 Group-A operators.
- Determinism preserved: the setup route is itself solver-planned + trace-golden'd.

### B. Concrete view-map effects for expand/collapse (`ui-planner-cov-views`)
Make expand/collapse plannable by emitting their effect as CONCRETE, unit-parametric
`slot_control` fluents drawn from the manifest's per-unit view lists:
- `tools/extract_operators.py`: for `expand(u)` / `collapse(u)`, bind the effect from
  `ui-model.manifest` `units[u].views.expanded` / `.collapsed` — the M1..M6 →
  control map — emitting `slot_control(Mi, <control>)` add/remove fluents (and the
  header/overview slot). The operator is parameterized by u; the solver grounds the
  effect per-unit at plan time.
- Solver: ground `expand(u)`/`collapse(u)` from a goal `slot_control(Mi, c)` +
  `focused_unit(u)`, consulting the manifest view map. `--run` drives the header-MAIN
  + ENTER toggle (the crawler's resolved gesture) and asserts the slot_control set.
- Add a corpus goal `expand-unit-controls` (insert a core unit, expand, assert its
  `slot_control(M2, <e.g. V/oct>)`). Closes expand + collapse + the `slot_control`
  fluent type.
- Note: this makes `slot_control` a first-class goal target — an agent can now ask
  "put control X on slot M2" and the planner routes through expand.

### C. Multi-unit focus + focused_class (`ui-planner-cov-focus`)
- Add a corpus goal `two-units-focus-first`: goal
  `{unit_in_chain(A), unit_in_chain(B), focused_unit(A)}` from boot — plan
  `insert(A)` (focus A) → `insert(B)` (focus B) → `focus_unit(A)` (re-focus A). This
  exercises `focus_unit` as a distinct op (A* must route back to A). Use two core
  lua-builtin units.
- `focused_class`: add it as a DERIVED effect on the operators that determine it —
  nav operators set `focused_class(<window class>)` (known from the ui-map node's
  recognize/class), and `focus_unit`/`insert` set `focused_class(Unit.Base.Header)`
  (or the observed focused class). Emit from `extract_operators.py` where statically
  known; verify live. Closes `focus_unit` + the `focused_class` fluent type.

### D. Durable-modal operators (`ui-planner-cov-modals`)
Model the modals that ARE stable end-states as new operators (precondition→effect+
gesture, crawler-resolved like the others):
- `enter_favorites_edit` (picker, shift-hold → `modal(favoritesEditMode)`),
  `enter_mark_mode` (sequencer S2 → `modal(markingMode)`),
  `build_selection` (sequencer shift+encoder → `modal(selectionActive)`). Each a real
  durable modal an agent might target. Crawl-resolve the gestures + preconditions; add
  a corpus goal per operator. Closes the `modal` fluent type for durable modals.
- **Legitimately permanent gap:** `modal(editingL1)` (and any transient in-edit modal)
  is NOT a stable end-state — document it as an intentional non-goal, not a coverage
  hole. Coverage's denominator should exclude intrinsically-transient modals.

## 2. Target + honesty

Target after all four: **operators 20/20** (or every operator with a documented
reason it can't be a goal target), **fluent-types 9/9** for durable fluents, with
`editingL1`-class transients explicitly excluded from the denominator rather than
counted as failures. The coverage file already documents WHY each gap exists; this
plan converts "documented gap" into "covered" wherever the gap was an artifact
(A, C-focus) or a modeling shortcut (B, C-focused_class, D-durable), and keeps the one
genuine gap (transient modals) as an explicit exclusion.

## 3. Build order (independent-ish; A + B are the highest value)

1. **`ui-planner-cov-starts`** (A) — non-boot starts + 5 nav goals. Pure corpus/runner
   enhancement; no operator changes. Fastest, closes 5 of 8 operators.
2. **`ui-planner-cov-views`** (B) — concrete expand/collapse effects. Touches
   extract_operators.py + solver + a goal; makes `slot_control` a goal target (high
   agent value). Re-run the ui-operators + goal-corpus gates.
3. **`ui-planner-cov-focus`** (C) — multi-unit focus goal + focused_class derived
   effect.
4. **`ui-planner-cov-modals`** (D) — durable-modal operators + crawl + goals; largest
   (new operators + a crawl pass), do last.

Each: verify via the tests/emu harness (plan + --run + trace-golden), regenerate the
committed operator/coverage artifacts through their gates, and the coverage headline
number rises monotonically. Constraints as ever: stdlib-only host tools,
app.EMULATION-guarded runtime, no od/hal firmware changes, no ML in routing or gate,
`[stol:]` anchors, no self-flipping ledger status.

*When this facility and the code drift, the code wins — update this doc.*
