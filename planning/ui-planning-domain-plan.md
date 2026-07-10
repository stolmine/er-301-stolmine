# UI planning domain — deterministic goal-routing over the 301 UI

*Goal: give agents FOREKNOWLEDGE of how to work the firmware, not just how to
navigate it — a machine-readable, BDG-ledgered model of the UI as a planning
domain, with example-goal coverage, so an agent can dynamically route to an
arbitrary end-state without looking anything up. Spec for the `ui-planner-*`
ledger cluster. Builds directly on the ui-model facility (planning/ui-model-plan.md).*

## 0. Thesis: this is a PLANNING problem, not a LEARNING problem

The instinct to reach for ML is the one to resist, and the reason tells us what to
build instead. ML (RL specifically) earns its keep when the environment is
**stochastic**, its transition model is **unknown/hidden**, or the state space is so
large you must **generalize from samples**. The 301 UI has none of these:

- **Deterministic** — proven. Same gesture in the same state → the same result.
- **Model fully observable in source** — every transition is a Lua handler we read;
  `emu.uiState()` gives perfect observation of the live state.
- **Small navigational state space** — dozens of contexts, a handful of gestures
  each; BFS/Dijkstra traverses it trivially. (The *parameter* space is large but is
  never searched — it's computed, e.g. C3 = 3.0 V.)

RL would spend its whole budget *learning* the two things this system hands us for
free (the model and the state). Worse, a learned router is **AI in the gate**, which
the ledger regime's cardinal rule forbids — you could never deterministically certify
a plan. So ML in the routing/execution/gate layer doesn't just fail to help; it
destroys the property that makes the facility trustworthy. Conventional planning is
not merely feasible here — it is the correct and superior tool.

**Where intelligence-of-the-fuzzy-kind legitimately lives:** the *authoring
boundary* — translating underspecified human intent ("a walking bassline") into a
FORMAL goal (a set of fluents). That is an LLM translation task done at plan time
(exactly what a human/agent does by hand), and its output — the formal goal — is then
handed to the deterministic planner and BDG-verified. The LLM proposes the goal; the
machine proves the route. The learned part stays strictly OUTSIDE the gate.

## 1. The formalism: a planning domain, not a nav mesh

The nav-mesh intuition is ~90% right but the wrong formalism. A nav mesh is
continuous *spatial* pathfinding over a baked static topology. The UI is a **discrete
labeled transition system with conditional, PARAMETRIC edges**: "open picker" only
exists when an empty insert slot is focused; "set cell" carries a parameter (3.0 V).
A flat mesh cannot express preconditions or parameters; a **planning domain** can.

- **Fluents** — a factored state of typed facts: `context=sequencer`,
  `focused-class=Sequencer.GridView`, `linked(1,2)`, `unit-in-chain(Network)`,
  `focused-unit(Network)`, `column-cursor(cv1)`, `cell(slot0, cv1, row, 3.0)`,
  modal flags. A **goal is a PARTIAL assignment** of fluents. "First 6 steps of cv1
  at C3" is six `cell()` fluents — nothing more.
- **Operators** — each a `(precondition → effect)` over fluents PLUS the concrete
  gesture sequence it emits. `link(a,b)`: pre `adjacent(a,b) ∧ ¬linked(a,b)`, eff
  `linked(a,b)`, gesture = the SELECT chord. `open-picker`: pre `context=chain ∧
  empty-insert-focused`, eff `context=picker`. `insert(u)`, `focus(u)`,
  `set-cell(slot,col,row,v)`. These operators ARE the manifest's handler→target
  edges, lifted into typed, composable actions.
- **A plan** = an operator sequence whose chained effects satisfy the goal fluents,
  found by classical search (BFS/A*/Dijkstra, or a small STRIPS/PDDL-style solver).

This generalizes today's `tools/ui_plan.py` from a few hardcoded goal-types
(link/insert/focus/control_at) to ARBITRARY fluent goals over a growing operator
library. The "bridge built over time" is exactly the operator library: near-end =
primitives (have), far-end = goal fluents (the schema), bridge = operators (grown).

## 2. What we already have vs the gap

| have (ui-model facility) | role in the domain |
|---|---|
| control protocol + `press/turn/...` | operator gesture emission |
| `emu.uiState()` | live state → fluents (the observation function) |
| `ui-map.toml` (verified context edges) | the context-navigation operators (seed) |
| `ui-model.manifest` (handler→target) | partial operator extraction |
| `tools/ui_plan.py` (BFS + live fallback) | the solver, in embryo (hardcoded goals) |
| trace hooks + trace-golden | plan verification |

**The gap:** the manifest resolves only ~7% of handler targets statically (the rest
are `dynamic`). A clean operator library needs those resolved. The answer is NOT
learning — it is a **conventional crawler with a perfect oracle** (§4).

## 3. Layer — state schema (`ui-planner-state-schema`)

Define the fluent vocabulary: the typed facts that describe any reachable UI state,
and the extraction from `uiState()` → a canonical fluent set. Cover: context/window
stack, focused class + focused unit, per-slot control identity, channel link state,
chain contents, sequencer cursor + cell values, and the known modal flags. Emit as a
stable schema doc (`docs/UI_STATE_SCHEMA.md`) + a `uiState → fluents` function
(reuse/extend `xroot/emu/UIState.lua`; the fluent projection can be a host-side
normalizer over the JSON so no new Lua is strictly required). Goals are expressed in
THIS vocabulary. This is the far-end contract; do it first.

## 4. Layer — operator library + crawler (`ui-planner-operators`, `ui-planner-crawler`)

- **Operators (static seed):** lift `ui-map.toml` edges + the manifest's resolved
  handler→target entries + `ui_plan.py`'s current goal-types into a typed operator
  table (`testing-assets/emu/ui-operators.toml`): id, params, precondition fluents,
  effect fluents, gesture template. Committed, BDG-diffed like the manifest.
- **Crawler (`ui-planner-crawler`) — the highest-value new build.** A conventional
  UI explorer: from each reachable state, systematically drive each candidate gesture,
  observe the ACTUAL resulting state via `uiState()`/trace, and record the empirical
  operator (pre-state fluents → gesture → post-state fluents). This is graph
  exploration with a PERFECT ORACLE — no learning, no generalization, just
  search + observation. It converts every `dynamic` manifest entry and every
  unmapped edge into a *verified* operator, and discovers preconditions empirically
  (e.g. "open-picker needs an empty-insert slot focused; the column is M3 mono / M4
  after a stereo link"). Output is a diffable BDG artifact; re-crawling on an
  unchanged build is a no-op diff, and any UI change shows up as an operator delta.
  Bound the crawl (depth, visited-state hashing on the fluent projection, avoid
  destructive/irreversible gestures via a denylist) and log what it skipped.

## 5. Layer — generalized solver (`ui-planner-solver`)

A classical planner (`tools/ui_solve.py`, stdlib-only) over the operator library:
input a goal (partial fluent assignment) + current state (from `uiState()` or boot),
output a gesture sequence via forward/backward search (A* with a cheap admissible
heuristic — e.g. count of unsatisfied goal fluents). `--run` drives the headless emu
and confirms arrival with fluent asserts + a trace-golden; a failed operator becomes a
corrected operator/precondition (the library self-heals from planning failures, same
pattern `ui_plan.py` already uses for map-growth suggestions). Supersedes the
hardcoded goal-types in `ui_plan.py` (keep `ui_plan.py` as a thin front-end or fold
it in).

## 6. Layer — example-goal corpus + coverage (`ui-planner-goal-corpus`)

The "example goal coverage" you want, as a BDG artifact: a corpus under
`testing-assets/emu/goals/` of `(goal, plan, trace-golden)` triples — canonical
end-states an agent can consult as worked examples AND regression goldens. Seed with
the ones we've already proven by hand: stereo-link + insert Network with glitch on M1;
sequencer cv1 first-6-steps at C3; reach admin/scope/sequencer; open/close picker.
Each regenerates (plan from the current operator library, execute, diff the trace) so
the corpus is always live. **Coverage metric:** which fluents / operators have at
least one verified example goal — a number the ledger tracks, so "how much of the UI
can agents reach with foreknowledge" is measurable and grows monotonically.

## 7. BDG governance + how it composes

- Every layer's data is a committed baseline diffed on every run: the operator table,
  the crawler map, each goal golden. `scripts/dev ui-model` grows to `ui-domain`
  (extract operators + crawl-diff + goal-corpus check), exit 1 on drift.
- The gate stays purely deterministic: extraction, crawl-observation, classical
  search, byte-diff. No model in the gate. The LLM (if used) only authors goals into
  the fluent vocabulary, upstream of the gate.
- Composes with the harness: trace-golden verifies every planned run; the reachability
  test generalizes to "every operator's precondition/effect holds live"; `uiState()`
  is the observation function throughout.

## 8. Build order (incremental, all conventional, all gateable)

1. **`ui-planner-state-schema`** — the fluent vocabulary + `uiState→fluents`. Small; first.
2. **`ui-planner-operators`** — lift map+manifest+ui_plan goal-types into the operator table.
3. **`ui-planner-crawler`** — empirically resolve `dynamic` operators + discover preconditions; BDG map.
4. **`ui-planner-solver`** — classical A* over the operator library for arbitrary fluent goals; `--run` verified.
5. **`ui-planner-goal-corpus`** — worked-example goldens + coverage metric in the ledger.

Constraints (all layers): stdlib-only host tools; any runtime Lua `app.EMULATION`-
guarded; no `od/`/`hal/` firmware changes; verify against the tests/emu harness;
crawler must avoid destructive gestures and bound its search; no learned component in
the routing or the gate — LLM only at goal authoring, upstream. Do not self-flip
ledger status; place `[stol:]` anchors.

*When this facility and the code drift, the code wins — update this doc.*
