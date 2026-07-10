# Deterministic UI model for agent-driven 301 operation — plan

*Goal: let agents understand and work the ER-301 UI deterministically, by reference
to code, verified through the headless-emu harness. Spec for the `ui-model-*` ledger
cluster. Motivating proof: the 2026-07-10 "Network on M1" run derived every gesture
from source (link chord from UserMode.lua, picker from EmptySection.lua, glitch-on-M1
from Network's expanded view list) — this facility turns that manual read into a tool.*

## 0. Why the 301 UI is deterministically analyzable (verified facts)

The UI is a **dispatch-by-named-method state machine over a window/context stack**:

- **Input → gesture events.** Physical buttons map to a fixed `notify(event, ...)`
  vocabulary in `xroot/Application.lua`. The complete set (verified):
  `shiftPressed/Released`, `encoder(change, shifted)`, and
  `{up,zero,home,commit,enter,cancel,dial}{Pressed,Released,Repeated}`, plus the
  indexed `{main,sub,select}{Pressed,Released,Repeated}(i, shifted)` (main i=1..6,
  sub i=1..3, select i=1..4). That's the whole gesture alphabet.
- **Routing.** `notify(e,...)` → `visibleContext:notify(e,...)`
  (`Application.lua:224`). `Context:notify` (`Base/Context.lua:226`) tries a context
  handler `self[e]` first, else `self:top():getFocusedWidget(e):sendUp(e,...)`.
- **Focus + chain of responsibility.** `Window:getFocusedWidget(e)` =
  `focus["all"] or focus[e] or self` (`Base/Window.lua:77`). `Widget:sendUp`
  (`Base/Widget.lua:173`) walks the widget→parent chain calling the first object
  that defines `[e]`. So the **affordance set at any moment = the union of gesture
  events for which some object in the focus chain (or the context) defines a
  handler.**
- **Layout.** A focused unit's controls sit at M1–M6 in the order of its
  `views.expanded` (or `.collapsed`) list; `addSpotDescriptor{center=...}` gives
  cursor/spot positions. "Network's glitch on M1" is just `expanded[1] == "glitch"`.

Both the *state* (context/window/focus/layout) and the *affordances* (which gestures
the focus chain accepts) are therefore knowable — statically from the Lua, or
dynamically by reflecting live objects. This plan builds both, plus a planner.

## 1. Shared contract: the gesture vocabulary + slot map (both layers use this)

- **Gesture tokens** (the control-protocol side already speaks buttons; this is the
  logical layer): `enter`, `up`, `home`, `zero`, `commit`, `cancel`, `dial`,
  `shift`, `encoder<±N>`, `main<1-6>`, `sub<1-3>`, `select<1-4>`, each with
  `pressed/released/repeated` where applicable and an optional `shifted` modifier.
  Map to the emu control protocol: e.g. logical `main3.released` → `press MAIN3`;
  `select1.hold + select2` → the link chord. Document the mapping once.
- **Slot map:** M1..M6 ↔ the focused unit's `expanded`/`collapsed` view list index;
  sub row S1..S3 ↔ subView controls; the header/spot at cell (0,0). Record the exact
  convention (from `Unit/ViewControl` + `SpottedStrip`) so "control at M1" is
  unambiguous.

Both the runtime API and the static manifest emit against THIS vocabulary so their
outputs are directly comparable (a natural BDG cross-check: live affordances at a
node should be a subset of the manifest's declared affordances for that class).

## 2. Layer 1 — runtime introspection API (`ui-model-introspect`) — build first

A deterministic "describe the current UI + what I can do here" endpoint, driven
through the existing emu bridge (the `emu` SWIG module + the `Application.lua`
EVENT_DISPLAY_READY drain; same path as `lua`/trace).

- **`emu.uiState()`** (Lua, `app.EMULATION`-guarded) returns a structured table
  (serialized to JSON on one `@`-reply line) with:
  - `context`: visible context instance name + class.
  - `stack`: window class names top→bottom.
  - `focus`: focused widget class + instance, and the focus-chain classes (the
    `sendUp` walk) so the agent sees who would handle a gesture.
  - `controls`: for the focused unit/window, each control with `slot` (M1–M6 / S1–S3
    / header), `name`, `class`, and `value`/`readout` where cheaply available.
  - `gestures`: the affordance set — for each gesture token in §1, whether some
    object in the focus chain OR the context defines the handler, and WHICH object
    (so the agent knows enter goes to EmptyControl:enterReleased → activateChooser).
    Derive by reflecting `handler = obj[event]` along the chain (no need to call it).
  - `modals`: known modal flags on the focused view (editingL1, markingMode,
    bpmLatched, favorites-edit, scene-authoring) discovered generically where possible.
- **Determinism:** pure function of UI state; no side effects; frame-stamped like
  trace. Same state → identical JSON (mind map/table ordering — sort keys).
- **Reflection mechanics:** enumerate §1 gesture tokens; for each, walk
  `focus:getFocusedWidget(e)` then the parent chain (`sendUp` order) collecting any
  object with a non-nil `[event]` field; also check the context's `[event]`. This is
  exactly the routing `Context:notify`/`sendUp` perform, read-only.
- **Verify (emu harness):** tests/emu scripts assert `uiState()` at known nodes:
  at boot `gestures` includes `main3.released` handled by an EmptyControl and its
  target resolves to the chooser; after inserting Network, `controls` shows glitch
  at slot M1. Golden the JSON (frame-stripped) as a `!ui-golden`, or `!assert` on
  fields. This makes the API itself BDG-checked.

## 3. Layer 2 — static behavior manifest (`ui-model-manifest`) — extract-and-diff BDG

An offline, whole-surface map extracted from `xroot/` (+ package unit files), so
agents can plan WITHOUT the emu and any UI change is caught by a diff.

- **`tools/extract_ui_model.py`** (stdlib-only) walks the Lua and emits
  `testing-assets/emu/ui-model.manifest` (stable, sorted, deterministic):
  - Per Window/Control/Mode class: the gesture handlers it defines (grep for method
    defs matching the §1 vocabulary: `function X:enterReleased`, `X.subReleased =`,
    etc.), and for each, a best-effort **static target** — scan the handler body for
    transition calls (`:show()`, `Context:add`, `doCommand("...")`, `activateChooser`,
    `setViewMode`, `notify(...)`); resolvable → named target, else `dynamic`.
  - Per unit (core + package `*.lua` with `views = {expanded=..., collapsed=...}`):
    the M1–M6 slot→control mapping and the overview/graphic control identity.
  - The context/mode graph seed (UserMode/AdminMode entry gestures) to cross-link
    with `ui-map.toml`.
- **BDG gate:** regenerate on every run, diff against the committed manifest; a
  mismatch means the UI changed — human accepts (intended) or fixes. Wire into
  `scripts/dev` alongside the ledger render (`extract → diff` in the commit path,
  or a `dev ui-model` subcommand + a tests/emu check). Follows the ledger doc's
  extract_contract pattern (extract from code, commit manifest, diff always).
- **Cross-check with Layer 1:** a tests/emu step drives the emu to each manifest
  node and asserts the live `uiState().gestures` ⊆ the manifest's declared
  affordances for that class (catches both stale manifest and reflection gaps).

## 4. Layer 3 — path planner (`ui-model-planner`) — after 1+2

Given a goal (e.g. `{link:[1,2], insert:"Network", focus:"Network", control_at:{M1:"glitch"}}`),
produce a gesture sequence:
- Context-level navigation: BFS over `ui-map.toml` edges (verified) from the current
  node to the target context.
- Control-level actions: consult the manifest (offline) or `uiState()` (live) for the
  gesture that triggers the needed transition (open picker, choose unit, focus, expand).
- **Verify by driving:** emit the plan as control-protocol lines, run headless, and
  confirm arrival with `uiState()` asserts + a `!trace-golden`. A failed plan step
  becomes a new/corrected `ui-map.toml` edge (the map grows from planning failures).
- Ship as `tools/ui_plan.py` (offline planner) + a tests/emu integration that plans
  and executes the Network-on-M1 scenario end-to-end as the canonical acceptance test.

## 5. Layer 0 — gesture catalog doc (`ui-model-gesture-catalog`)

The human+agent-readable operator's manual: `docs/UI_OPERATION.md`, the §1 vocabulary
+ slot map + the canonical gestures (link chord, open/close picker, focus/expand a
unit, enter/exit admin/scope/sequencer) with their control-protocol sequences,
generated/verified from the manifest so it never drifts. This is the quick-reference
an agent reads before planning; the manifest is the exhaustive machine form.

## 6. How it composes with the existing harness

- `ui-map.toml` (verified contexts) = the skeleton; Layer 1/2 add focus/control depth.
- Trace hooks + `!trace-golden` = the verifier for every planned run.
- Reachability test = already walks map edges; extend to assert `uiState()` at each.
- Ledger/BDG regime = governance: the manifest is a committed baseline that must match
  a fresh extract, so the UI model cannot silently diverge from the code.

## 7. Build order + dispatch

1. **Layer 1 (`ui-model-introspect`)** and **Layer 2 (`ui-model-manifest`)** in
   parallel — disjoint files (Layer 1: emu bridge + a Lua describe module + tests;
   Layer 2: a host python extractor + manifest + a dev subcommand). Worktree-isolated.
2. **Layer 0 (`ui-model-gesture-catalog`)** falls out of Layer 2 (generated from the
   manifest) — the manifest agent produces it.
3. **Layer 3 (`ui-model-planner`)** after 1+2 land and are verified (needs both as
   inputs). Held for a follow-up dispatch.

Constraints (all layers): `app.EMULATION`-guard any runtime Lua so hardware is
untouched; no `od/`/`hal/` firmware changes; stdlib-only host tools; verify against
the tests/emu harness; do not self-flip ledger status; place `[stol:]` anchors.
