# Hold-Mode Scenes — Phase 4: Engine Apply (Crossfader)

Status: planning. Branch: `feature/hold-mode-scenes`. Predecessor:
phase 3c (commit `7b02785`) + Fader brightness/order (`d2b438a`).
Successor: phase 4 lands the audio side; phase 5 is final polish,
3d is the pin-icon overlay.

## Why this phase exists

Phase 3 stores scene deltas in a flat map keyed by unit instance
key + control id. Authoring captures them; the Performance view
displays slot summaries. Nothing yet drives audio with those
deltas. A scene is currently inert storage.

Phase 4 wires a CV-driven crossfader to interpolate live audio
parameters between two endpoints (scene A, scene B, or base) at
audio-rate resolution. After phase 4, plugging a CV (or running an
internal LFO) into the M1 picker source crossfades between the two
slots assigned to the A and B endpoints; deltas in those slots
move the actual audio path.

## Engine primitive

The OG hold mode uses `od::ParamSetMorph` (existing C++ class):
holds a list of `(param, startValue, endValue)` items + a weight
`mWeight` Parameter. `apply()` computes `w1*start + w2*end` and
`softSet`s each param. `add(param, endValue)` snapshots
`startValue = param->target()` at add-time -- one endpoint is
"wherever the param is now."

That snapshot semantic is wrong for an A/B crossfader, where both
endpoints are explicit (scene A's stored delta vs scene B's). Two
options for getting (start, end) explicit:

**(a) Extend ParamSetMorph in place.** Add a 3-arg
`add(param, startValue, endValue)` overload; existing 2-arg call
unchanged so PinView keeps working.

**(b) New class `SceneMorph` (or similar).** Modelled on
ParamSetMorph but with the 3-arg add as the only add, plus a
built-in CV inlet (see below). Leaves ParamSetMorph alone.

(a) is the minimum-churn path and is what this plan goes with. The
2-arg add stays; we just add a 3-arg overload that doesn't snapshot.

## CV → weight wiring

`ParamSetMorph::process()` is currently a no-op. The PinView morph
runs via `apply()` called from `MorphFader::draw` (UI thread, frame
rate) -- adequate for a hand-driven knob, not for CV that may need
audio-rate response.

For scene crossfading we want audio-rate response so a fast CV
sweep doesn't audibly granulate. Three approaches:

1. **Inlet on the morpher.** Add an Inlet to ParamSetMorph;
   `process()` reads `inlet[N-1]` (or averaged), softSets `mWeight`,
   calls `apply()`. CV is connected via the standard chain wiring
   (Lua-side: `AudioThread::connect(cvOutlet, &morpher->mInlet,
   morpher)`). Drives `mWeight` per audio frame.

2. **Separate writer object.** A small dedicated Object that takes
   an inlet and writes its samples into a target Parameter's mTarget
   via softSet. CV → writer → morpher.mWeight. More objects, more
   wiring, but doesn't change ParamSetMorph behavior.

3. **No CV at all.** Frame-rate only, no inlet, user controls
   weight via a Lua-side tick reading the picked source's value. UI
   thread runs at 60fps -- fine for slow LFO modulations, audibly
   coarse for fast sweeps.

Going with **(1)**: smallest user-visible code change, cleanest CV
path, and the morpher is already an Object so it slots into the
existing graph machinery. Falls back gracefully when no CV is
picked: if `mInlet` has no connection, `process()` keeps
`mWeight` at the last hardSet value (which we set to 0 = full-A
when nothing is wired).

Also have `process()` call `apply()` each frame regardless of
weight change. Cheap; the existing `mUpdateNeeded` short-circuit
inside apply still skips the param softSets when nothing moved.

Note: the existing OG hold-mode path (frame-thread apply from
`MorphFader::draw`) is untouched. PinView's morph keeps running at
frame rate; only scene-mode morph runs at audio rate.

## Lifecycle: engage / disengage / rebuild

A single `SceneMorph` instance per Chain.Root, lazily created.

**Engage** (one morpher armed, audio-rate):
- Triggered when entering Performance view (sceneHoldContext active).
- Walks every delta-able control via `_walkAllUnits` (same walker
  as 3c authoring).
- For each delta-able param, computes
  `(startValue = sceneA's delta for this param, else base)` and
  `(endValue = sceneB's delta, else base)`.
- Calls `morpher:add(param, startValue, endValue)` (the new 3-arg
  overload).
- Connects the picked CV outlet to `morpher.mInlet`.
- Adds the morpher to a per-root ObjectList task and starts the
  task so audio-rate processing fires.

**Disengage** (back to user-edit):
- Triggered when leaving scene mode (`setMode("edit")`) or before
  destroying the chain.
- Tears down the ObjectList task wiring, clears morpher items,
  disconnects the CV inlet. The audio path snaps back to whatever
  each param's `target()` is -- no abrupt jumps because the
  morpher's last `softSet` left each at its interpolated position.

**Rebuild** (without disengaging):
- After exiting scene authoring (the just-edited scene's deltas
  may have changed): rebuild item list with the same A/B
  assignments, preserving the morpher's `mWeight`.
- After A/B crossfader role change (Performance view S1 cycle):
  rebuild item list with new A/B sources, preserve weight.
- After scene add / delete that affects A or B: rebuild.

Each rebuild = `morpher:clear()` then re-walk + re-add. Cheap;
typical patches have tens of delta-able controls. `mWeight` is
preserved so the audio doesn't pop on assignment changes.

## Base snapshot semantics

When a control has no delta in scene A (or B), that endpoint = "base
value". Base = the param's `target()` at the time we engage. This
is the user's pre-scene-mode setting (since user-edit mode locks
when authoring runs, and the Performance view doesn't allow
encoder writes to base).

**Captured once at engage**, stored alongside the morpher. Used
for any param the user hasn't assigned a delta to in the active
scene. NOT re-captured on rebuild (rebuilds happen when A/B or
deltas change, not when base changes -- which it shouldn't during
scene mode anyway since the structural-edit lock is active).

On disengage, base is forgotten. Next engage re-captures from
whatever the user did in user-edit between scene sessions.

## Where the morpher lives

`Chain.Root` field, lazily created. Mirrors the existing
`getSceneView()` lazy pattern. Methods:
  - `Root:getSceneMorph()` -- lazy create + return.
  - `Root:engageSceneMorph(sceneView)` -- build items + connect.
  - `Root:disengageSceneMorph()` -- tear down.
  - `Root:rebuildSceneMorph()` -- clear + re-add items, preserve
    weight + task connection.

`ChannelGroup.setMode("hold")` triggers engage after the
`enterPerformanceView` call. `ChannelGroup.setMode("edit")`
triggers disengage before the editContext activation.

The Performance view's S1 (cycle A/B) handler calls
`chain:rebuildSceneMorph()` after updating the scene index
assignments.

## Decibel-domain morph

ParamSetMorph already honors `Parameter::mEnableDecibelMorph`:
items with the flag morph in dB-space. Preserved automatically
since we're reusing the same Item struct (just the new add
overload).

## Sub-tasks

### 4.1 ParamSetMorph 3-arg add overload

`add(Parameter *p, float start, float end)` -- store both
explicitly, skip the `target()` snapshot. Item ctor variant that
takes both. No effect on existing 2-arg path.

### 4.2 CV inlet on ParamSetMorph

Add `Inlet mInlet{"CV"}` to ParamSetMorph. `process()`:
  - Read last sample of `mInlet.buffer()`.
  - Clamp to [0, 1].
  - `mWeight.hardSet(sample)`.
  - Call `apply()`.

`apply()`'s existing `mUpdateNeeded` short-circuit handles the
"weight didn't change" case so the per-param softSet loop is
skipped when CV is static.

Verify PinView still works: it never connects mInlet, so the
hardSet-from-inlet path no-ops at zero (or whatever the inlet
default is) -- but the inlet is also nil and shouldn't be
processed. **Open: confirm Inlet behavior with no connection.**

### 4.3 Chain.Root.getSceneMorph + lifecycle

Lua-side wrapper that holds:
  - `app.ParamSetMorph` instance (new C++ overload now available)
  - `app.ObjectList` task for audio-rate processing
  - Saved base values map: `{[unitKey][ctrlId] = baseValue}`
  - Engaged flag

`engageSceneMorph(sceneView)`:
  - Capture base values (walker + control:getSceneBaseValue).
  - Get A/B scene indices from sceneView.
  - For each delta-able param, compute aValue + bValue, call
    `morpher:add(controlParam, aValue, bValue)`.
  - Lock task, clear, add morpher, unlock, start.
  - Wire CV input outlet (from sceneView:getCvInput) to
    morpher.mInlet via AudioThread::connect.

`disengageSceneMorph()`:
  - Disconnect CV outlet from morpher.mInlet.
  - Stop + clear task.
  - Clear morpher.
  - Drop saved base values.

`rebuildSceneMorph()`:
  - Lock task.
  - Clear morpher items.
  - Re-walk + re-add with current A/B assignments + saved base.
  - Unlock. Weight preserved.

### 4.4 ChannelGroup wiring

`setMode("hold")` with sceneMode on, after
`getSceneView():enterPerformanceView()`:
  - `self.chain:engageSceneMorph(self.chain:getSceneView())`.

`setMode("edit")`:
  - Before activating editContext, if scene mode was active:
    `self.chain:disengageSceneMorph()`.

The existing setMode("edit") auto-exit-from-scene-authoring path
also needs disengage (already calls exitSceneAuthoring on the
chain -- add disengage after).

### 4.5 Performance view rebuild triggers

S1 cycle A/B on a scene slot: after updating `crossfaderA` /
`crossfaderB`, call `chain:rebuildSceneMorph()`.

Scene add: rebuild if the new scene index displaces A or B (it
shouldn't, since add appends).

Scene delete: `removeScene` already shifts A/B; rebuild after.

Scene authoring exit (return from authoring view): rebuild because
the authored scene's deltas may have changed and the morpher's
endpoint values need updating.

### 4.6 CV picker connection

The Performance view M1 picker sets `sceneView:setCvInput(sourceRef)`
on selection. Need a way to resolve sourceRef → outlet for
AudioThread::connect.

Existing pattern: `Source.ExternalChooser` returns a source
descriptor that includes the outlet. Need to either:
  - Have the picker remember the outlet alongside the ref string.
  - Resolve ref → outlet at engage-time via `Source.find(ref)` or
    similar.

Whichever PinView / external-source-aware controls already use --
audit and reuse.

CV source change while engaged: disconnect old, connect new,
without disturbing the task. Performance view should call a small
`chain:setSceneCvInput(outlet)` helper.

### 4.7 Edge cases

- **No CV picked**: morpher.mInlet has no connection. `process()`
  reads inlet samples -- need a sane default. Either skip
  hardSet-from-inlet when inlet is unconnected, or hardSet to 0
  (full A). Plan: skip; user manually sets weight via... TBD. Or
  expose a soft default in Performance UI.
- **No scenes assigned**: crossfaderA = crossfaderB =
  kEndpointBase (= 0). All deltas resolve to base on both ends ->
  no movement on weight change. Audio unchanged.
- **One endpoint scene, other base**: works naturally -- base
  endpoint just uses captured base value for every param.
- **Scene has no delta for a given param**: that param's endpoint
  value = base. Morph between base and base = no movement (one
  endpoint), or movement only when the OTHER endpoint differs.
- **Param with audio-rate modulation already feeding it**: morph
  softSets target; whatever audio-rate modulation runs after is
  unaffected. Same as how OG hold mode behaves.
- **mEnableDecibelMorph**: existing Item handles it (toDecibels /
  fromDecibels at add-time and in apply).

## Open questions

1. Inlet behavior with no connection -- safe to `process()`
   without checking? Audit `Inlet::buffer()` for null-source
   behavior.
2. CV source identifier: what does the picker actually store, and
   how do we resolve back to an outlet at engage time? Probably
   `Source.find(ref)` -- verify in 4.6.
3. Weight scaling / mapping: should CV map linearly 0..1 to A..B,
   or should there be a curve (s-curve, exponential)? Plan: linear
   for 4.0, add an option for 5 polish.
4. Audio-rate vs frame-rate cost: with ~50 delta-able params and
   `apply()` per audio frame, do we eat audible CPU? Profile
   during 4.7 bench.
5. Task ownership: per-Root or per-ChannelGroup? Per-Root because
   the morpher is on the chain, but the task is what schedules it
   to run at audio rate. Verify the per-Root task model works with
   the existing Chain processing pipeline.
6. Restart-after-disengage: does the morpher's mPreviousWeight
   need resetting so apply()'s short-circuit fires correctly on
   re-engage? Probably yes -- add `reset()` call to clear.

## Out of scope for 4

- Pin icon overlay on delta'd controls in regular user-mode (3d).
- Multi-CV per-param crossfade (M2/M3/M4 each with own CV instead
  of one shared) -- stays single-CV per chain.
- Curve / response shaping on the weight (linear only for 4.0).
- Persisting the picked CV source ref across power-cycle -- the
  ref string is already serialized via SceneView, but
  resolve-on-load needs a verify pass.

## Implementation order

1. 4.1 ParamSetMorph 3-arg add (C++).
2. 4.2 CV inlet on ParamSetMorph (C++) -- emu boot smoke test
   that PinView still works.
3. 4.3 Chain.Root scene-morph lifecycle methods.
4. 4.4 ChannelGroup engage/disengage hooks.
5. 4.5 Performance view rebuild triggers.
6. 4.6 CV picker connection wiring.
7. 4.7 Bench verify: assign A/B, plug CV, hear audio interpolate.
   Profile if CPU looks high.

Each step ships as its own commit. After 4.7 the feature does what
it says on the tin: scenes drive audio via CV crossfading.
