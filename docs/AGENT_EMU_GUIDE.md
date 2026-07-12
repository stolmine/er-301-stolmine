<!-- [stol:ui-model-planner][stol:ui-planner-solver] Agent-facing playbook. Keep the
     command examples runnable; they are the whole point of this doc. -->
# Driving the ER-301 headless emu: an agent's playbook

If you can run the headless emu but find yourself reading `xroot/` source to work
out how to reach some screen or set some value, stop. The UI is **deterministic and
fully observable**, and there is a planning facility that turns "get me into state
X" into real gestures for you. Code-crawling to navigate is the anti-pattern this
doc exists to kill.

The rule: **introspect, then plan. Do not reverse-engineer navigation by reading
handlers.** You read source only to EXTEND the model (add an operator/fluent), not
to USE it.

## The mental model (why planning works here)

- Every reachable UI state projects to a small, typed set of **fluents**
  (`context(sequencer)`, `focused_unit(Test Osc #1)`, `cell(0,cv1,0,3.0)`, ...).
  See `docs/UI_STATE_SCHEMA.md`.
- `emu.uiState()` is a **perfect oracle**: it reports exactly where you are and
  what is possible right now.
- Transitions are a fixed library of typed **operators** (precondition to effect,
  each carrying the gesture that fires it): `testing-assets/emu/ui-operators.toml`.
- So "reach state X" is a classical **search** problem (forward A* over fluents),
  not a learning problem and not a source-reading problem. `tools/ui_solve.py`
  does the search and can drive the emu to execute + verify the plan.

## The three moves

### 1. Run the emu

Two entry points, both hermetic and deterministic:

- **A scripted test.** Author a `tests/emu/<name>.test` (control-protocol commands
  + `!assert` predicates) and run it:
  ```
  tools/emu_test.py 57-ui-solve-c3-sequencer      # one test by basename
  tools/emu_test.py                                # the whole suite (TAP)
  ```
  Command grammar (`down/up/press`, `turn N`, `frames N`, `stable N`, `cap PATH`,
  `lua CODE`, `!assert LUA`, `!expect REGEX`, `!trace-golden`) is in
  `tests/emu/README.md`. Needs the headless emu core built: `scripts/dev build`
  (or `make emu`), binary at `testing/linux-x86_64/emu/emu.elf`.

- **The planner drives it for you** (see move 3, `--run`). You often never write a
  `.test` at all: you hand `ui_solve` a goal and it boots, routes, and asserts.

### 2. Look: where am I, and what can I do?

Ask the live UI, do not guess from source. On the app Lua thread:
```
lua return emu.uiState()          # full JSON: context, focus, stack, affordances
```
`docs/UI_STATE_SCHEMA.md` §"Assembling the bundle" has the exact `lua` one-liners
that build the fluent projection bundle (extended state + supplementary readback),
and §"Worked example states" shows what boot, the sequencer, and a stereo-linked
chain look like in fluents.

### 3. Go: route to a goal (this is the part people skip)

Express the destination as a **partial fluent goal** and let the solver find the
gestures. Two tools, pick by what your goal talks about:

- **`tools/ui_solve.py`** — arbitrary fluent goals (units, cells, links, focus,
  columns, modals). This is the general one.
  ```
  # print the offline operator plan + rendered gestures:
  tools/ui_solve.py --goal 'context(sequencer);column_cursor(cv1);cell(0,cv1,0,3.0)'
  # actually drive the emu, assert each effect, then satisfies(state, goal):
  tools/ui_solve.py --goal '<...>' --run
  # goal from a file (a .goal in the corpus, or your own):
  tools/ui_solve.py --goal-file testing-assets/emu/goals/seq-cv1-c3.goal --run
  # start somewhere other than boot:
  tools/ui_solve.py --from 'context(sample_pool)' --goal 'context(admin)' --run
  ```
- **`tools/ui_plan.py`** — when the goal is just "be at context node N" (a map
  location). Lighter; BFS over `testing-assets/emu/ui-map.toml`.
  ```
  tools/ui_plan.py --goal '{"context":"scope"}' --run
  ```

Sanity-check either tool offline with `--selftest` (no emu needed).

## The obstacle table (replace code-crawl with a tool)

| You are tempted to... | Do this instead |
|---|---|
| grep handlers to find the gesture for some screen | `docs/UI_OPERATION.md` §"Canonical gestures" (verified live) + the `slot_control`/`notify` tables |
| trace `sendUp`/`notify` to work out how to reach a screen | `tools/ui_solve.py --goal 'context(<node>)' --run` |
| figure out how to set sequencer cells by hand | goal with `cell(slot,col,row,value)` fluents; solver emits the real ENTER to L1-edit encoder path |
| work out how to open the picker on a NON-empty chain | it is the `insert_after` operator (opens via the focused unit's `Chain.InsertControl`); the solver routes it, you do not hand-craft it |
| confirm you actually arrived | `--run` already asserts `satisfies(state, goal)`; or `!assert` in a `.test`; never eyeball a screenshot for state |
| find valid values/slots for a fluent | `docs/UI_STATE_SCHEMA.md` §"The vocabulary" (arities + domains) |

## Worked examples (all from the committed corpus, all runnable)

```
# Headline: sequencer cv1 column, rows 0..5 all at C3 (3.0 V), via the real
# encoder edit path. Plan = nav home->scope->sequencer, select_column, 6x set_cell.
tools/ui_solve.py --goal-file testing-assets/emu/goals/seq-cv1-c3.goal --run

# Multi-unit + re-focus: insert two units, focus the FIRST. Plan forces
# insert_after -> insert -> focus_unit (a genuine re-focus, not an idempotent skip).
tools/ui_solve.py --goal-file testing-assets/emu/goals/two-units-focus-first.goal --run

# Indirect nav: arrive at admin FROM the sample pool (forces the return edge).
tools/ui_solve.py --goal-file testing-assets/emu/goals/admin-via-sample-pool.goal --run
```
Each `<name>.goal` in `testing-assets/emu/goals/` ships its offline `.plan` (the
operator sequence) and a frame-stripped `.trace` (the live route). Read those to
see, per goal, exactly what the solver decided and what happened. They double as
regression goldens (`scripts/dev goal-corpus`).

## The catalogs (the model, in three files)

- **Gestures** (Layer 0): `docs/UI_OPERATION.md` — logical gesture vocabulary and
  the gesture to emu control-protocol mapping. Remember there is **no encoder
  push-button** on the ER-301; any "encoder click" is ENTER / M / S / CANCEL.
- **State schema** (fluents): `docs/UI_STATE_SCHEMA.md` — the goal language.
- **Operators** (transitions): `testing-assets/emu/ui-operators.toml` — 22 typed
  operators (nav_*, open_picker, insert, insert_after, focus_unit, set_cell,
  select_column, build_selection, expand, collapse, link, ...). Empirical rules for
  the runtime-resolved ones live in `testing-assets/emu/ui-crawl.map`.

Coverage today: 22/22 operators, 8/8 meaningful goal-fluent types
(`testing-assets/emu/goal-coverage.txt`). If a goal you need is inside that
envelope, the solver reaches it. If it is not, you extend the model (below), you do
not hand-drive around it.

## Determinism rules (so runs are reproducible)

- Gate on **frames, not milliseconds** (`frames N` / `stable N`). Host load moves
  wallclock but not the frame-indexed render sequence.
- The screensaver "breathing cursor" tween never settles; the settings fixture
  disables it. Capture screenshots only after a `frames`/`stable` settle.
- `--seed N` makes the RNG deterministic. The harness builds a per-test hermetic
  FRONT/REAR sandbox, so runs do not bleed state.

## When the model genuinely does not cover your goal

Only then do you read source, and even then you extend the model rather than
one-off it:

1. Missing a **transition**: add an `[[operator]]` to `ui-operators.toml`; if its
   gesture is runtime-dependent, mark it `needs_crawl` and let
   `tools/ui_crawl.py` (`scripts/dev ui-crawl`) resolve it against the live emu.
2. Missing a **fluent**: extend `tools/ui_fluents.py` + `docs/UI_STATE_SCHEMA.md`.
3. Then add a `.goal` to the corpus and re-run `scripts/dev goal-corpus` so the new
   capability is a worked example + golden.

Design + provenance for all of this: `planning/headless-emu-plan.md`,
`planning/ui-model-plan.md`, `planning/ui-planning-domain-plan.md`.
