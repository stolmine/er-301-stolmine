# Hold-Mode Scenes — Phase 4: Engine Apply (CV Crossfader)

Status: planning (revised after design Q&A). Branch: `feature/hold-
mode-scenes`. Predecessor: phase 3c (commit `7b02785`) + Fader
brightness (`d2b438a`). Successor: phase 4 lands audio; phase 5
final polish; 3d is the pin-icon overlay.

## Why this phase exists

Phase 3 stores scene deltas. Phase 4 wires them to audio: a single
ParamSetMorph per Chain.Root interpolates live audio params between
sceneA and sceneB endpoints. CV (or manual encoder, or any mod
source the user wires up) drives the weight.

## Design decisions (locked)

Confirmed via user Q&A:

1. **Weight = linear 0..1.** CV value clamped, no curve. Curves
   land in phase 5 if useful.
2. **Weight source = GainBias-style control (NOT bare CV inlet).**
   M1 slot becomes a standard GainBias control: bias = manual
   weight (encoder), gain = CV attenuator, mod branch = user-
   extensible. User drops whatever they want in the sub-chain.
3. **Audio follows the encoder live during authoring.** Editing
   scene A's controls while the crossfader is full A produces
   audible changes immediately. Requires morpher items to read
   endpoint values live from Parameters, not cached floats.
4. **Base = recaptured every engage.** Snapshot from each audio
   param's `target()` at engage time. Catches the user's user-mode
   final state without per-edit hooks.

## Architecture overview

Three things land:

- **`ParamSetMorph` extension.** A new Item variant takes
  `(targetParam, startParam, endParam)` — three `Parameter*`s.
  `apply()` reads `startParam->target()` and `endParam->target()`
  every frame, computes `w1*start + w2*end`, softSets target. Old
  2-arg path (start = snapshot at add-time) unchanged for PinView.
- **Persistent scene Parameters.** Each Scene owns
  `params[unitKey][ctrlId] = app.Parameter` (sparse). Created
  lazily on first delta; survives scene mode entry/exit. The same
  Parameter is what authoring's encoder writes to AND what the
  morpher reads for its endpoint. No copy step, no rebuild on
  authoring transition.
- **GainBias-driven weight.** Chain.Root owns an `app.GainBias`
  + mod branch ("scene-cv"). Its `Out` feeds the morpher inlet
  (audio rate). M1 slot in Performance becomes a GainBias
  ViewControl bound to this object. Bias = manual weight; gain
  attenuates whatever the user wires into the mod branch.

## Persistent scene Parameters

Replaces Phase 3's float-only delta map for in-memory state.
Serialization stays float-based for forward/backward compat:

```lua
-- Scene.lua
function Scene:init(args)
  ...
  self.params = {}   -- params[unitKey][ctrlId] = app.Parameter
  self.deltas = {}   -- floats; only used for serialize/deserialize
                     -- and as the source of truth before params exist
end

function Scene:getOrCreateParam(unitKey, ctrlId, baseValue)
  local u = self.params[unitKey] or {}
  self.params[unitKey] = u
  if u[ctrlId] == nil then
    local stored = self.deltas[unitKey] and self.deltas[unitKey][ctrlId]
    u[ctrlId] = app.Parameter(ctrlId .. "_" .. self.name,
                              stored or baseValue)
  end
  return u[ctrlId]
end

function Scene:serialize()
  -- Walk params, copy target() into deltas, then serialize deltas.
  for unitKey, ctrls in pairs(self.params) do
    self.deltas[unitKey] = self.deltas[unitKey] or {}
    for ctrlId, param in pairs(ctrls) do
      self.deltas[unitKey][ctrlId] = param:target()
    end
  end
  return { ..., deltas = self.deltas }
end

function Scene:deserialize(t)
  -- Just load deltas; Parameters created lazily on demand.
  self.deltas = t.deltas or {}
  self.params = {}
end
```

Phase 3 authoring (Chain.Root.enterSceneAuthoring) now uses
`scene:getOrCreateParam(unitKey, ctrlId, baseVal)` instead of
building an ephemeral `app.Parameter`. Encoder writes go to that
persistent param; on authoring exit there's no value capture step
— the Parameter holds the right value.

## Base snapshot

Chain.Root holds `_sceneBaseParams[unitKey][ctrlId] = app.Parameter`,
lazily created. On engage, walk all delta-able controls and
`baseParam:hardSet(audioParam:target())` so base = current user-
mode value at the moment scene mode was entered. Refresh on every
engage (= every time user re-enters Performance from user-edit).

Base Parameters live as long as the chain. Reused across engages.

## Morpher items

Lua wrapper:

```lua
function Root:engageSceneMorph(sceneView)
  local morph = self:getSceneMorph()  -- lazy create
  morph:clear()

  -- Refresh base from current user-mode values.
  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneBaseValue then
        local baseParam = self:_getOrCreateBaseParam(unitKey, ctrlId)
        baseParam:hardSet(control:getSceneBaseValue())
      end
    end
  end)

  -- Build items.
  local aIdx = sceneView:getCrossfaderA()
  local bIdx = sceneView:getCrossfaderB()
  local sceneA = aIdx > 0 and sceneView:getScene(aIdx) or nil
  local sceneB = bIdx > 0 and sceneView:getScene(bIdx) or nil

  _walkAllUnits(self, function(unit)
    if not unit.controls then return end
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.getSceneAudioParam then  -- new control method, see below
        local audioParam = control:getSceneAudioParam()
        local baseParam  = self._sceneBaseParams[unitKey][ctrlId]
        local baseVal    = control:getSceneBaseValue()
        local aParam = sceneA and sceneA:hasDelta(unitKey, ctrlId)
                       and sceneA:getOrCreateParam(unitKey, ctrlId, baseVal)
                       or baseParam
        local bParam = sceneB and sceneB:hasDelta(unitKey, ctrlId)
                       and sceneB:getOrCreateParam(unitKey, ctrlId, baseVal)
                       or baseParam
        morph:add(audioParam, aParam, bParam)
      end
    end
  end)

  app.AudioThread.addTask(self.sceneTask, 0)
end
```

`control:getSceneAudioParam()` is a new method per control type
that returns the actual audio-rate Parameter being driven (e.g.,
for a GainBias control it's `biasParam`; for a Fader it's the
fader's value param). Different from `getSceneBaseValue()` which
returns a float; this returns the Parameter pointer the morpher
should softSet.

Need to add this method to the same 6 ViewControl classes that
got `enterSceneMode` in phase 3.

## CV input via GainBias

```lua
function Root:_buildSceneCV()
  if self.sceneCVGainBias then return end
  self.sceneCVGainBias = self:addObject("scene-cv", app.GainBias())
  self:addMonoBranch("scene-cv", self.sceneCVGainBias, "In",
                     self.sceneCVGainBias, "Out")
  -- Connect the GainBias Out to the morpher's CV inlet (added in 4.2).
  app.AudioThread.connect(self.sceneCVGainBias:getOutput("Out"),
                          self.sceneMorpher:getInput("CV"))
end
```

Performance view M1 slot:
- Replaces the Source.Chooser picker.
- Becomes a Unit.ViewControl.GainBias instance bound to the chain's
  scene-cv GainBias object.
- Encoder edits bias (= manual weight).
- S1 dives into the scene-cv branch (where user adds External CV
  / LFO / S&H / whatever).
- Sub display shows the gain readout + branch view (standard
  GainBias subgraphic).
- M1's bias label = "weight" or "x-fade"; mod button shows the
  branch contents like any GainBias.

This means the SceneView no longer stores a serialized CV ref
string. The CV source is part of the chain's audio graph (in the
scene-cv branch) and serializes with the chain like any other mod
chain. Drop `SceneView.cvInput` / `setCvInput` / `getCvInput` in
favor of the GainBias branch.

## Audio-rate apply

`ParamSetMorph::process()` is currently a no-op. Modify it:
- Read last sample of `mInlet.buffer()`.
- Clamp to [0, 1].
- `mWeight.hardSet(sample)`.
- Call `apply()`.

`apply()`'s existing `mUpdateNeeded` short-circuit handles the
"weight didn't change AND no items modified" case so static-CV
periods don't softSet 50 params per frame.

PinView still works because its morpher's mInlet is never
connected (Inlet returns ZeroOutput = zeros = weight 0 = full
start value = pre-engage state = correct for the unused-morpher
case).

## Lifecycle

**Engage:**
- Triggered by `setMode("hold")` with `sceneMode == "on"`, after
  `getSceneView():enterPerformanceView()`.
- Refresh base Parameters from audio param.target() (live user-
  mode values).
- Build morpher items per A/B assignments.
- `addTask` so audio-rate apply runs.
- Lazily build the scene-cv GainBias + branch on first engage.

**Disengage:**
- Triggered by `setMode("edit")`.
- `removeTask` to stop audio-rate apply.
- Clear morpher items.
- Base Parameters stay (cheap; reused next engage).

**Rebuild (no disengage):**
- A/B cycle on Performance S1: morpher.clear() + re-add items
  with new A/B sources. Weight preserved.
- Scene add/delete that displaces A or B: rebuild.
- Scene authoring exit: **no rebuild needed.** Morpher items
  reference scene Parameters directly; any value changes are
  already visible to apply() through the live target() reads.

**Authoring entry / exit:**
- Entry: Chain.Root.enterSceneAuthoring still runs (3b walker).
  It now uses `scene:getOrCreateParam(...)` instead of building an
  ephemeral Parameter. Encoder writes hit the persistent param.
  Morpher (engaged) already references that param — audio follows
  live as the user turns the encoder.
- Exit: param values stay in place. Scene.serialize() captures
  them into the float deltas map on next save. No morpher rebuild.

## What changes in Phase 3 code

The persistent-Parameter approach touches Phase 3 in two small
ways:

1. **Scene.lua** gets `params`, `getOrCreateParam`, `hasDelta`.
   serialize/deserialize bridge between `deltas` (float, on-disk)
   and `params` (Parameters, in-memory).
2. **Chain.Root.enterSceneAuthoring** uses
   `scene:getOrCreateParam(unitKey, ctrlId, baseVal)` instead of
   `app.Parameter(ctrlId .. "_scene", deltaVal)`. The Parameter
   returned is the persistent one — no value capture on exit.
3. **Chain.Root.exitSceneAuthoring** no longer needs to capture
   target values into the scene's delta map. It just walks armed
   controls and calls `control:exitSceneMode()` to restore the
   widget. Optional: prune scene params whose target() matches
   base (avoids accumulating no-op deltas across many authoring
   sessions). Cheap; do it.

Both changes are local. The walker, subtitle, lock, egress
gestures, brightness-render swap — all unchanged.

## Sub-tasks (revised)

### 4.1 ParamSetMorph extension: 3-Parameter add + live apply

Add a new Item variant: `Item(Parameter *target, Parameter *start, Parameter *end)`
holding all three pointers. Stored alongside the existing 2-arg
items in `mItems` (a tagged union or sibling vector).

`add(Parameter *target, Parameter *start, Parameter *end)` —
queues the new variant.

`apply()`: for each item, if Parameter-variant, read
`startParam->target()` and `endParam->target()` live; compute
`w1*start + w2*end`; softSet on targetParam. If 2-arg-variant,
use existing float startValue / endValue path.

Decibel-morph flag honored if the target Parameter has
`mEnableDecibelMorph` set (existing logic, just transferred to
the new path).

Existing PinView code stays on the 2-arg path.

### 4.2 ParamSetMorph CV inlet + audio-rate process

Add `Inlet mInlet{"CV"}`. process(): read `mInlet.buffer()[last]`,
clamp [0,1], hardSet mWeight, call apply(). Inlet unconnected ->
`ZeroOutput.buffer()` -> sample=0 -> weight=0 -> full A.

PinView morpher unaffected: inlet stays unconnected (zeros);
PinView's apply call from `MorphFader::draw` still drives its own
weight via the morphFader encoder.

### 4.3 Persistent scene Parameters

Modify `Scene.lua`: add `params` map, `getOrCreateParam`,
`hasDelta`. Bridge to existing `deltas` map at serialize /
deserialize. Authoring uses the Parameters; on-disk format stays
float-only for compat.

### 4.4 Per-control getSceneAudioParam

Add `control:getSceneAudioParam()` returning the audio-rate
Parameter pointer to drive. 6 ViewControl classes (Fader,
BranchMeter, Pitch, GainBias, Gate, InputGate). For most, it's
`self.fader:getValueParameter()` (the live audio param, which is
also what `getSceneBaseValue` reads target() on). For Gate /
InputGate, it's `self.threshold:getParameter()`.

### 4.5 Chain.Root scene-morph + scene-cv

`Root:getSceneMorph` lazy create the morpher + task. `Root:_buildSceneCV`
lazy create the GainBias + branch + connect Out -> morpher CV
inlet. `Root:engageSceneMorph` / `disengageSceneMorph` /
`rebuildSceneMorph`. Base Parameter map.

### 4.6 Performance view M1 = GainBias control

Replace the Source.Chooser picker. M1 becomes a Unit.ViewControl.GainBias
bound to the chain's scene-cv GainBias object. Adopts the standard
GainBias UX: encoder = bias, S2/S3 = focus gain/bias, S1 = mod
branch dive. Drop SceneView.cvInput / setCvInput / getCvInput +
their serialize fields. Migration: ignore old cvInput on load
(user re-wires via dive).

### 4.7 ChannelGroup engage/disengage hooks

`setMode("hold")` with sceneMode on: engage after enterPerformance.
`setMode("edit")`: disengage before activating editContext. Auto-
exit-from-authoring safety: also disengage.

### 4.8 Performance view rebuild triggers

S1 cycle A/B -> rebuild. Scene add/delete -> rebuild.

### 4.9 Phase 3 cleanup

Switch enterSceneAuthoring to use `scene:getOrCreateParam` instead
of ephemeral params. exitSceneAuthoring: drop the float capture
step; optional prune of base-matching scene params.

### 4.10 Bench + profile

Plug a CV (or use the M1 encoder for manual), assign A/B, hear
audio interpolate. Profile CPU with ~50 delta-able params.

## Out of scope for 4

- Pin icon overlay (3d).
- Curve / s-curve weight mapping (phase 5 if useful).
- Multi-CV per-param (single weight only).
- Loading old-format cvInput from existing presets (drops on
  load; user re-picks via M1 dive).

## Implementation order

1. 4.1 ParamSetMorph 3-Parameter Item + apply (C++).
2. 4.2 CV inlet + process audio-rate apply (C++). Boot smoke
   test PinView still works.
3. 4.3 Scene persistent Parameters (Lua).
4. 4.4 Per-control getSceneAudioParam (Lua).
5. 4.5 Chain.Root scene-morph + scene-cv lifecycle (Lua).
6. 4.6 Performance M1 GainBias rewrite (Lua).
7. 4.7 ChannelGroup hooks (Lua).
8. 4.8 Performance rebuild triggers (Lua).
9. 4.9 Phase 3 cleanup (Lua).
10. 4.10 Bench + profile.

Each step its own commit. After 4.10 the feature drives audio:
plug a CV, hear scenes blend.
