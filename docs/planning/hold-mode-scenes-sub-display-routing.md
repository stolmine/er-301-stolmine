# Hold-mode scenes: sub-display Parameter routing

## Goal

Extend the per-control state machine (introduced in phase 3b) so
every Parameter a ViewControl exposes via an editable Readout
participates in scene authoring + the A↔B crossfade.

Why now: the impl plan said all continuous params should be
delta-able, including sub-display-only ones on habitat units
(Plaits, Clouds, Warps, etc.). The 3b implementation only covered
one Parameter per ViewControl — sufficient for Fader / Pitch /
BranchMeter / Gate / InputGate but not for GainBias (which has
both a bias readout and a gain readout) and not for the habitat
units that lean heavily on sub-display knobs.

## Current state (post `.27`)

The per-control protocol in phase 3b is:

```lua
control:enterModulatedDisplay(audioParam, baseParam)
control:enterSceneMode(sceneTargetParam)
control:exitSceneMode()
control:exitModulatedDisplay()
control:getSceneAudioParam() -> Parameter
control:getSceneBaseValue() -> float
control:getSceneTargetValue() -> float
```

One audio Parameter, one base Parameter, one scene target. Scene
deltas keyed by `[unitKey][ctrlId]` where `ctrlId` is the control
instance name. One value per `(unitKey, ctrlId)`.

GainBias.lua *does* swap `self.bias` (the sub-display bias readout)
to the scene target on `enterSceneMode`, but `self.bias` reads the
*same* Parameter as the main fader (Bias). Editing self.bias and
editing the main fader both write to one Parameter. The gain
readout (`self.gain`) is bound to a different Parameter (Gain)
that's never scene-routed.

## Target state

Each ViewControl declares a *map* of named scene slots, one per
editable Parameter:

```lua
function GainBias:getSceneParameters()
  return {
    main = self.bias:getParameter(),   -- the M-key fader / bias readout
    gain = self.gain:getParameter(),   -- the sub-display gain readout
  }
end

function Fader:getSceneParameters()
  return { main = self.fader:getValueParameter() }
end
```

`slotKey = "main"` is the canonical name for the primary param
(matches the existing single-slot model on migration). Other slots
are unit/control-specific strings: `"gain"` for GainBias, whatever
naming a future habitat-specific control needs.

Scene deltas extend to a three-level map:
```
scene.deltas[unitKey][ctrlId][slotKey] = float
```

Same for `scene.params`. Chain.Root's `_sceneBaseParams` extends too:
```
chain._sceneBaseParams[unitKey][ctrlId][slotKey] = Parameter
```

Morpher items are per `(unitKey, ctrlId, slotKey)` triple rather
than per `(unitKey, ctrlId)` couple.

## Architecture extension

### ViewControl protocol additions

New base method on `Unit.ViewControl`:

```lua
function ViewControl:getSceneParameters()
  -- Return { [slotKey] = audioParam, ... } for every editable
  -- Parameter this control exposes. Default: nil (control isn't
  -- delta-able).
  return nil
end
```

Per-slot variants of the existing enter/exit methods. Two design
options:

**Option A (recommended)**: extend the existing methods to take
a slot key.

```lua
function GainBias:enterModulatedDisplay(slotKey, audioParam, baseParam)
  -- swap the readout bound to slotKey
end
function GainBias:enterSceneMode(slotKey, sceneTargetParam)
  -- swap the readout bound to slotKey
end
function GainBias:exitSceneMode(slotKey) ... end
function GainBias:exitModulatedDisplay(slotKey) ... end
function GainBias:getSceneBaseValue(slotKey) -> float ... end
function GainBias:getSceneTargetValue(slotKey) -> float ... end
```

Caller (Chain.Root) iterates `getSceneParameters()` and calls
each per-slot method.

**Option B**: opaque "slot handle" object that bundles all the
readouts + base params + scene targets. Each ViewControl returns
a list of slot handles; each handle has its own enterScene /
exitScene / getValue methods.

Option A: less ceremony, more direct mapping of existing API.
Option B: cleaner OO if slots get more behavior later.

Pick A for v1.

### Schema migration

`Scene.lua` deserialize handles both shapes:

```lua
function Scene:deserialize(t)
  if t == nil then return end
  if t.name then self.name = t.name end
  if t.deltas then
    -- Old format: deltas[unitKey][ctrlId] = float.
    -- New format: deltas[unitKey][ctrlId][slotKey] = float.
    -- Migrate old -> new on load: treat the float as the "main"
    -- slot.
    self.deltas = {}
    for unitKey, perUnit in pairs(t.deltas) do
      self.deltas[unitKey] = {}
      for ctrlId, value in pairs(perUnit) do
        if type(value) == "number" then
          -- old single-slot format
          self.deltas[unitKey][ctrlId] = { main = value }
        else
          -- new multi-slot format
          self.deltas[unitKey][ctrlId] = value
        end
      end
    end
  end
  self.params = {}
end
```

`Scene:serialize` always writes the new format. Once a preset is
saved on `.28+` it's permanently in the new shape; loading on
earlier firmware would expect a float and break. This is a
one-way migration.

Acceptable: scenes haven't shipped to users yet (`feature/hold-mode-scenes`
hasn't merged to develop). Pre-merge presets carry only test data.

### Chain.Root walker extension

Existing `_armControlModulated` becomes per-slot:

```lua
function Root:_armControlModulated(unitKey, ctrlId, control)
  if not (control.getSceneParameters
          and control.enterModulatedDisplay) then return end
  local slots = control:getSceneParameters()
  if not slots then return end
  for slotKey, audioParam in pairs(slots) do
    local baseParam = self:_getOrCreateBaseParam(unitKey, ctrlId, slotKey)
    if not self:_isControlSlotArmed(control, slotKey) then
      baseParam:hardSet(audioParam:target())
      control:enterModulatedDisplay(slotKey, audioParam, baseParam)
    end
  end
end
```

`_isControlSlotArmed` is a new per-control field check
(`control._modAudioParams[slotKey] ~= nil` -- each control stores
per-slot state).

Same shape for `enterSceneAuthoring` / `exitSceneAuthoring`
walkers: iterate slots.

`_buildSceneMorphItems` produces one `addVee` per slot:

```lua
for slotKey, audioParam in pairs(slots) do
  local baseParam = self:_getOrCreateBaseParam(unitKey, ctrlId, slotKey)
  local aParam = baseParam
  if sceneA and sceneA:hasDelta(unitKey, ctrlId, slotKey) then
    aParam = sceneA:getOrCreateParam(unitKey, ctrlId, slotKey, baseVal)
  end
  -- same for B
  morph:addVee(audioParam, baseParam, aParam, bParam)
end
```

## Per-ViewControl audit

| Control | Slots after change | Notes |
|---|---|---|
| Fader | `main` | No behavioral change; just the new method shape |
| BranchMeter | `main` | Same |
| Pitch | `main` | Same (the sub readout reads the same Parameter) |
| Gate | `main` (threshold) | Same |
| InputGate | `main` (threshold) | Same |
| GainBias | `main` (bias) + `gain` | New: gain readout becomes scene-routable |
| Habitat-specific multi-knob controls | depends per unit | Each habitat author opts in by overriding `getSceneParameters` |

Each of the 5 single-slot controls needs a `getSceneParameters`
that returns `{ main = ... }` and per-slot adapters on the four
enter/exit/get methods. The adapters can ignore slotKey since
they have only one slot, but the signature change ripples through.

GainBias gets the genuinely new code: separate base + scene target
per slot, separate readout-binding swap on enter / exit.

## UX

### Sub-display delta indicator

Per-readout dog-ear glyph on the sub-display ply corner showing
the readout has a stored delta in the active scene. Generalizes
the existing main-display `_setSceneAuthoringIndicator` mechanism
to take a position arg (which sub-display corner).

Render only on readouts whose slot has a non-nil delta in the
*currently authored* scene. Hide when no scene is being authored
or when the slot has no delta. Visibility refresh hook: scene
authoring enter / exit, encoder edit on the readout, delta
captured back on exit.

### Authoring focus model

In scene authoring the user can already focus the sub-display
readout (S2 / S3 on GainBias). With the protocol extension, that
focus path automatically writes to the scene target instead of
the audio Parameter — because `enterSceneMode("gain", ...)` swapped
the gain readout's Parameter binding the same way `enterSceneMode("main", ...)`
swaps the bias readout's.

No new gesture needed. The existing focus mechanism just works
once the binding swap is per-slot.

## Implementation order

1. **Schema migration in Scene.lua**: extend `deltas` to
   three-level map; backward-compat deserialize; new shape
   serialize.
2. **ViewControl base method**: add `getSceneParameters()` default
   returning nil; helper to determine "is delta-able."
3. **Per-control adapters**: add `slotKey` arg to enter / exit /
   getBase / getTarget on the 6 existing delta-able controls.
   Single-slot controls just ignore the key.
4. **Chain.Root walkers**: extend `_armControlModulated`,
   `_armAllControlsModulated`, `enterSceneAuthoring`,
   `exitSceneAuthoring`, `_buildSceneMorphItems` to iterate
   slot keys.
5. **GainBias gets multi-slot**: `getSceneParameters` returns
   both `main` and `gain`. enter / exit / getBase / getTarget
   handle each slot's readout swap.
6. **Bench-verify**: GainBias with gain delta + bias delta in
   different scenes; A↔B crossfade should interpolate both.
   Authoring entry shows both readouts in scene-edit state.
7. **Sub-display delta indicator**: small dog-ear per readout
   showing per-slot delta presence in active scene.

Each step in its own commit so we can bisect.

## Test checklist

- [ ] Open Performance with `.27` saved preset (single-slot
      deltas). Verify the migration path correctly reads the
      old shape as `main` slot and the A↔B crossfade still
      works.
- [ ] In authoring, edit a GainBias bias value via encoder.
      Exit; re-enter. Original value preserved as scene delta.
- [ ] Same flow but edit the gain readout (S2 focus, encoder).
      Exit; re-enter. Gain delta preserved.
- [ ] Assign A to a scene with gain delta'd. Crossfade M1
      from B (= base) to A (= gain delta). Audio sweep
      reflects gain change.
- [ ] Assign A and B to different scenes, both with gain
      deltas. M1 sweep interpolates between the two gain
      values.
- [ ] Save preset, reload. Both scenes' main + gain deltas
      round-trip.
- [ ] Bias-fill indicator and behavior unchanged on
      single-slot controls (Fader / Pitch / etc.).
- [ ] Habitat unit smoke (Plaits multi-knob): if Plaits uses
      stock GainBias as its sub-display controls, those
      should automatically scene-route via the GainBias
      multi-slot extension. Confirm or note as follow-up.

## Risks

1. **Migration of saved scenes.** Old-format scenes lose their
   delta values if the deserialize migration path misfires.
   Mitigation: feature branch hasn't shipped; no real users
   have saved presets. Migration is exercised on test scenes
   only.
2. **ABI for `addVee`.** Unchanged (still 4-Parameter).
   `Scene.deltas` schema change is internal.
3. **Slot-key namespace collision.** If two ViewControls
   chose the same slot key for different params... mitigated
   by the per-control isolation (`deltas[unitKey][ctrlId][slot]`
   is scoped to one control).
4. **Per-slot state on ViewControl.** Each control needs to
   track `_modAudioParams[slotKey]`, `_modBaseParams[slotKey]`,
   `_sceneTargetParams[slotKey]`. Adds storage but the maps
   stay tiny (1-2 slots per control in practice).
5. **Performance.** ~50 morph items today (per `phase-4.md:361`).
   Multi-slot extension might double for GainBias-heavy
   chains. Should still be well under the CPU budget.

## Revert path

1. Revert the Chain.Root walker extension commit. Drops back
   to per-control-not-per-slot iteration.
2. Revert the per-control adapter commits. Single-slot shape
   restored.
3. Revert the Scene.lua schema extension last. Old format
   exclusive.

If migration produces incorrect deltas, recover from a
known-good earlier preset (the bench scenes used for testing
should be re-creatable).
