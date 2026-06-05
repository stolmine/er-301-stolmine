# Hold-mode scenes v1.1 plan: CV-controllable A / B scene selection

Canonical plan for the v1.1 bring-up. Driven by shellfritsch's
post-`.37` request (2026-06-04) and the design conversation that
produced the locked decisions below. Referenced from
`hold-mode-scenes-todos.md`.

Status: design locked. Awaiting v1.0 bench-validation settle before
phase 5.1 starts.

---

## Goal

Make A and B scene assignment first-class CV-controllable concepts,
on par with the M1 morph weight. Preserve continuous A↔B fading via
M1 (unchanged). Three writers compete for each of A and B (CV
subchain, encoder, scene chip tap) with a state-machine arbitration
that avoids the GainBias "manual permanently shifts CV envelope"
trap.

---

## Layout

Performance view becomes:

```
M1     M2  M3  M4    M5    M6    ...
morph  A   B   scene scene scene  (scroll for scenes 4..16)
                1     2     3
```

All controls participate in scroll, same as M1 already does today.
Default view shows M1 / M2 / M3 / scene1 / scene2 / scene3, but the
user can scroll right to push M1-M3 off the left edge and view up
to 6 scene plies at once. SpottedStrip camera handles this with
zero new code; the section just appends controls in order and the
strip pans them through the viewport. M1, M2, M3 share the same
dive/Gain/Bias sub-display shape so the row reads consistently.

---

## Engine

### M1 morph weight (unchanged)

Continuous A↔B blend via GainBias output feeding the ParamSetMorph
CV inlet. Same wiring, same UI, same persistence shape after the
multi-role refactor relabels its role to `"morph"`. Standard
`out = bias + gain * cvIn` semantics: bias is the static morph
position, CV adds to it. This is the right primitive for a
continuous blend.

### A and B selectors (new arbiter primitive)

Drop the GainBias sum semantics for A and B. The summing model
fails the "tap to select a scene with CV patched" UX because
writing bias permanently shifts the CV envelope (CV at 0V with
bias=3 gives A=3; CV sweeping 0-2 with bias=3 gives A sweeping 3-5,
not 0-2). Manual gets undue priority by reframing the CV operating
window, not by claiming the value.

Replace with a per-role `SceneIndexArbiter` C++ object that takes
a CV input and two Parameters (Gain, Bias), runs a 2-state machine
in `process()`, and exposes an effective-output Parameter that
drives the morpher.

**State machine:**

- **Tracking-Manual** (cold-start): output = `clip(round(Bias), 0, N)`.
  Encoder and chip taps write Bias. Output follows Bias in real time.
  CV input is ignored while here.
- **Tracking-CV**: output = `clip(round(Gain * cvIn), 0, N)`. Bias is
  preserved as the user's home but not consumed.
- **Manual → CV transition:** CV input value moves by more than a
  Schmitt threshold since the moment we entered Manual. Threshold =
  0.5 of a scene step in output space (i.e. `0.5 / Gain` in input
  space, recomputed when Gain changes).
- **CV → Manual transition:** any encoder write or chip tap on this
  role.
- **No idle decay.** Tracking-Manual only yields the floor when CV
  *moves*, not when time passes.

**Parameters:**

- `Bias`: scene-index space, range `[0, N]`, encoder + tap writers,
  clips when bank shrinks. Saved.
- `Gain`: unitless CV scaler, "scenes per unit input." Range
  `[-32, +32]` (lifted from the standard GainBias `[-10, +10]` cap
  so a sub-volt source can traverse a 16-scene bank). Default 1.0.
  Saved.

Math is intentionally framed to look like standard GainBias from
the user's perspective (Gain scales CV, Bias is the manual position).
The arbiter is what makes Bias and Gain not-additive. The fader's
visual contract telegraphs the difference.

### Visual contract per A/B fader

Mirrors the v1.0 modulated-display idiom users already know from
scene authoring:

- **Box** on fader = Bias position. The user's manual home / last
  asserted value. Persists through CV winning.
- **Line** on fader = effective output (integer-snapped to scene
  ticks). Equals box during Tracking-Manual; equals
  `round(Gain * cvIn)` during Tracking-CV. Box and line coincide
  right after a manual write, then line drifts away when CV next
  takes over.
- **Scope + range bar** to the right = CV input shape, same as M1.
- **Readout** = name of the scene currently at the line position
  (e.g. "vocal", "drone"). Implemented via the habitat
  `ModeSelector` pattern (`er-301-habitat/mods/biome/assets/
  ModeSelector.lua`): a GainBias-style control with a Lua-side
  `updateLabel()` that does `fader:setLabel(name)` from a names
  table indexed by the rounded effective output. No new Fader API
  needed. v1.1 extends the pattern by calling `updateLabel()` on
  the arbiter integer-transition signal in addition to user-input
  events, so CV-driven moves refresh the readout too.

### Live-index morpher consumption (no rebuild on integer transitions)

The ParamSetMorph today is built once at engage with sceneA / sceneB
resolved as Lua ints from `SceneView:getCrossfaderA/B()`. v1.1 makes
A and B live values that change at audio rate, and the audio
thread must own the entire scene-switch path so that UI starvation
(which happens under heavy load) does not introduce switching
latency.

Path: extend `ParamSetMorph` to consume live A/B indices through
two new Inlets (`IndexA`, `IndexB`) wired to the arbiter Outlets.
At engage, each delta-able control's item is built with the *full
per-scene Parameter list*, not just a resolved A and B endpoint.
In `apply()`, the morpher reads the last sample of each index
Inlet, clips to `[0, N]`, picks the right scene Parameters from
the per-item table, and runs the existing wA/wB linear blend.

- **No rebuild on integer transitions.** A/B index changes are a
  per-frame Inlet read. Latency = 1 audio frame.
- **Lua-side rebuild reserved for structural events.** Engage,
  scene add, scene delete, scene authoring changes. Those are all
  Lua events, safe to mutate `mItems` from Lua.
- **Audio thread is fully autonomous** for scene switching. UI
  starvation has zero effect on switching latency. Matches the
  301's audio-preserved-under-load invariant.
- **Bank UI updates (chip + bias-fill)** still consume an
  integer-transition signal from the arbiter for redraw. UI poll
  is acceptable here because the path is cosmetic: starved UI =
  stale visual, but audio is correct. The arbiter sets a
  transition-pending flag; SceneSlotControl reads it on its
  existing UI frame handler.

### ParamSetMorph extension shape

- Two new Inlets: `IndexA`, `IndexB`. Unconnected → ZeroOutput →
  last sample = 0 → resolves to baseParam (the "unassigned"
  semantic v1.0 already uses).
- New Item kind `kVeeIndexed` holding `target`, `baseParam`, and
  `std::vector<Parameter*> scenes` of length N+1 (index 0 =
  baseParam, indices 1..N = each scene's stored Parameter if it
  has a delta on this control, else baseParam).
- New `addVeeIndexed(target, baseParam, scenes)` builder, called
  by `_buildSceneMorphItems()` instead of the existing `addVee`.
- `apply()` switch handles `kVeeIndexed`: read IndexA/IndexB
  Inlets, clip, select scenes[A_idx] and scenes[B_idx], blend.
- Existing `addVee` and `kVee4` paths stay in the codebase for
  back-compat but are no longer emitted by the scene crossfader.

---

## Wiring

### Multi-role scene-CV branch map

Refactor `Chain.Root`:

- `_sceneCVBranch` → `_sceneCVBranches[role]`, role ∈
  `{"morph", "A", "B"}`.
- Same restructuring for `_sceneCVGainBias` (M1 only),
  `_sceneCVArbiter` (A and B only), `_sceneCVRange` (all three),
  `_sceneTask` ordering.
- `getSceneCVBranch(role="morph")` default keeps M1Control unchanged.

### Audio task ordering

All three roles' inputs and range trackers run before the morpher:

```
A.arbiter → A.range → B.arbiter → B.range → morph.gainBias →
morph.range → morph
```

A and B Outlets feed the morpher's IndexA/IndexB Inlets directly.
Morpher reads them per frame; consistent A/B/Weight per frame
follows automatically from task ordering (arbiters run before
morpher).

### Persistence

Schema bump. Legacy single `sceneCVBranch` + `sceneCVParams` loads
under role `"morph"`. Save format is now `sceneCVBranches` map keyed
by role, each entry carrying `branch` + `params`. Arbiter
Parameters (`Gain`, `Bias`) saved per role. Effective output is
transient, not saved. State machine state is transient, not saved
(cold-start always Tracking-Manual).

### Bank rewire

- SceneSlotControl's A/B chip + bias-fill side stop coming from
  `SceneView:getCrossfaderA/B()` (Lua int) and start coming from
  the arbiter integer-transition signal (UI-side poll, cosmetic).
- Performance polls the per-role transition flag on its existing
  UI frame handler and re-runs `_refreshSlotRoles()` on edge.
  Audio path does NOT depend on this; if UI stalls, the chips
  stop animating but audio scene switching is unaffected.
- `toggleEndpoint` (chip-tap S-key) rewires from
  `SceneView:setCrossfaderA(idx)` to `arbiterA:hardSetBias(idx)`.
  Forces Tracking-Manual via the standard manual-write path.
- `SceneView:getCrossfaderA/B()` becomes a computed read of
  `round(arbiterA.effectiveOutput)` for back-compat with any caller
  that still reads it (mostly serialize).

### Bank shrink behavior

Scene deletion clips both A and B Bias Parameters to `[0, N']`
where N' is the new bank size. No wrap. State preserved. If clip
moves the value, the existing engage-cycle rebuild picks up the
new endpoints on next morpher rebuild.

---

## Phase breakdown

Mirrors the v1.0 numbering. Each phase ends bench-stable before the
next starts.

### 5.1 Plan doc + arbiter spec + ParamSetMorph extension shape

- This document, plus the `SceneIndexArbiter` interface spec
  (`hold-mode-scenes-v1-1-arbiter-spec.md`).
- Schmitt = 0.5 scene step in output space (locked).
- Gain cap = ±32 (locked).
- Audio-thread autonomy for scene switching: arbiter Outlet feeds
  morpher Inlet, morpher consumes live A/B indices in `apply()`,
  no rebuild on integer transitions. UI poll is cosmetic-only.

### 5.2 Multi-role branch map refactor in Chain.Root

- Convert single-branch fields to role-keyed maps. Default role
  `"morph"` preserves v1.0 behavior; no new controls yet.
- Persistence migration: load legacy keys into `"morph"` role; save
  in new format.
- Bench: v1.0 behavior identical on existing saves and new saves.

### 5.3 SceneIndexArbiter + ParamSetMorph live-index extension

- New `SceneIndexArbiter` C++ object under `od/objects/control/`.
  Header + impl + SWIG registration. 2-state machine, Schmitt
  detection, integer-transition flag (UI-only consumer).
- ParamSetMorph extension: add `IndexA` / `IndexB` Inlets, new
  `kVeeIndexed` Item kind, new `addVeeIndexed(target, baseParam,
  scenes)` builder. `apply()` switch case for kVeeIndexed reads
  Inlets, clips, selects, blends.
- Engage path: `_buildSceneMorphItems()` emits `addVeeIndexed`
  with full per-scene Parameter list per delta-able control.
  Audio thread reads A/B indices live; no rebuild triggered by
  arbiter transitions.
- Wire arbiter Outlets to morpher Inlets via `AudioThread.connect`.
- Test in isolation before wiring to UI: instantiate arbiter +
  morpher, drive CV programmatically, verify A/B index changes
  produce correct morph output without any Lua-side calls.

### 5.4 SceneSelectorControl (shared M2/M3 class)

- Copy M1Control structure. Three sub-display slots: dive / Gain /
  Bias.
- Scene-name readout follows the habitat `ModeSelector` pattern
  (Lua `updateLabel()` calling `fader:setLabel(name)`). Refreshed
  on user-input events and on arbiter integer-transition signal.
  No Fader C++ API change.
- M2 instance bound to role "A", M3 to role "B".
- No bank rewire yet; both selectors render but writes still hit
  `SceneView:setCrossfaderA/B` for one bench-validation cycle to
  prove the controls work standalone.

### 5.5 Bank rewire

- Performance inserts M2 and M3 between M1 and the bank.
- SceneSlotControl chip + bias-fill driven by arbiter
  integer-transition signal, not `SceneView:getCrossfaderA/B()`.
- `toggleEndpoint` chip-tap path writes arbiter Bias.
- `SceneView:getCrossfaderA/B()` becomes computed.

### 5.6 Bench sweep

Coverage:
- CV unpatched: A/B behave like v1.0 manual selectors.
- Static CV at a non-zero value: Tracking-CV holds; tap a chip,
  output snaps to bias and stays; advance CV by less than Schmitt,
  output stays; advance CV past Schmitt, output yields back to CV.
- Slow sweep CV: smooth integer transitions with no boundary
  chatter at Schmitt-tuned threshold.
- Fast LFO CV: morpher rebuild cost visible under
  `app.AudioThread` profile? If yes, investigate amortization.
- Encoder during CV: output yields back to CV after Schmitt
  exceeded, not before.
- Persistence: save with all three roles populated, reload, verify
  Gain / Bias / branch contents and that state cold-starts
  Tracking-Manual.
- Stereo link/unlink (TODO #57): three-role case fails the same way
  one-role case fails today; no new corruption mode introduced.
- CPU profile vs v1.0 on a unit-dense chain.
- **UI-starvation test:** force a heavy UI workload (long
  paint, blocking Lua) and confirm CV-driven scene switching
  remains audibly clean and prompt. Audio path must be
  fully autonomous.

### 5.7 (deferred) Skip-include mask

Per-scene boolean. Arbiter integer-transition layer skips masked
indices so CV sweeps can hop over unwanted scenes. UI affordance
TBD (probably shift submenu on SceneSlotControl). Defer to first
bench complaint.

---

## Locked decisions

From the v1.1 design conversation:

- M1 morph fader and continuous A↔B blend preserved unchanged.
- A and B use a new arbiter primitive, not GainBias.
- Two states: Tracking-Manual (cold-start), Tracking-CV.
- Schmitt threshold = 0.5 scene step in output space.
- No idle decay from Tracking-Manual.
- Bias and Gain are the user-facing Parameters (familiar 301 idiom).
- Gain cap = ±32 (lifted from standard ±10).
- No Throw Parameter, no system preference for default scaling.
  Gain defaults to 1.0 like every other GainBias on the 301.
- No CV-input centering Parameter. Users patch an offset upstream
  if needed.
- Bias clips on bank shrink, no wrap.
- Custom scene-name readout under A/B faders (good UX regardless).
- Three plies for crossfader controls; bank shrinks from 5 visible
  to 3.

## Open items deferred to implementation

- Whether SceneIndexArbiter is a new C++ object or composed from
  existing primitives. Lean new class. (Decided in 5.3.)
- Synchronous vs Lua-scheduled morpher rebuild on integer edges.
  (Investigated in 5.1.)
- Scene-name readout implementation. (Decided: habitat
  `ModeSelector` pattern, no C++ changes.)
- Skip-include mask. (5.7, deferred.)
