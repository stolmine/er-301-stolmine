# Scene mode phase 3b: Authoring view with target+value display

**Status:** scope locked 2026-05-31 on `feature/hold-mode-scenes`.
**Companion to** `hold-mode-scenes-impl.md` (overall plan). This
doc is the detailed build spec for the meat of phase 3.

The user dove into the per-scene Authoring view in phase 3a but
landed on a placeholder. Phase 3b makes the Authoring view show
the chain's actual controls, with each delta-able control
rendering BOTH its current live value AND the scene's target
value via the same `app.Fader` two-parameter mechanism OG hold
mode uses.

## Architecture decision: mutate, don't mirror

The plan considered three architectures (snapshot-only, live
interception, overlay-and-restore). The "investigate og firmware"
direction revealed a fourth and cleanest option:

**Mutate the chain's existing edit-view controls in place** for
the duration of scene authoring. The dive doesn't build a new
view that mirrors the chain. It activates the chain's existing
`editContext` AND tells each delta-able control to enter
"scene mode," which swaps its widget's `controlParameter` from
its live `valueParam` to a new per-scene `targetParam` initialized
from the scene's delta (or current value if no delta yet).

This works because `app.Fader` (and the other delta-able widgets)
already supports the dual-parameter pattern:
- `setValueParameter(value)`: the live audio-thread value (display
  shows actual position).
- `setTargetParameter(target)`: the "aiming" value (display shows
  target marker).
- `setControlParameter(target)`: encoder writes go to this param.

In normal user mode, all three point at the same parameter. In
scene authoring, value stays at the live param while target is a
NEW per-scene param. Visually identical to OG hold mode pinned
display.

**Why this beats mirroring the chain:**
- No new SpottedStrip / Section / control widgets to build.
- All existing edit-view navigation (encoder, M-keys, unit row,
  sub display, dive into units, etc.) works unchanged.
- Adding a new unit type that supports scene authoring is a
  one-method addition to its ViewControl class.
- Diff is localized to a per-control mutate + restore pair.

**Why this beats snapshot-on-enter / capture-on-exit:**
- User sees live target marker as they author (the visual prep
  for the crossfade blend they're authoring).
- Re-entering the same scene shows the previously authored target
  values, not "reset to current."

## Delta-able controls

Control types whose ViewControl class already exposes
`getPinControl()` (i.e., already build a per-pinset wrapper for
hold mode) are the natural set:

| Type | File | Supports target+value? |
|---|---|---|
| Fader | xroot/Unit/ViewControl/Fader.lua | yes (app.Fader) |
| GainBias | xroot/Unit/ViewControl/GainBias.lua | yes |
| Pitch | xroot/Unit/ViewControl/Pitch.lua | yes |
| BranchMeter | xroot/Unit/ViewControl/BranchMeter.lua | yes |
| Gate | xroot/Unit/ViewControl/Gate.lua | gate-style (comparator threshold) |
| InputGate | xroot/Unit/ViewControl/InputGate.lua | gate-style |

Other control types (OptionControl, Clock, FileTransport,
OutputScope, etc.) don't have getPinControl and are NOT
delta-able. In scene mode they render normally; their encoder
writes still go to their underlying value (no scene interception).

## Control-side API

Each delta-able ViewControl gets two new methods, mirroring the
`getPinControl()` pattern:

```lua
function Fader:enterSceneMode(sceneTargetParam)
  -- Swap the widget's control parameter from valueParam to the
  -- caller-supplied sceneTargetParam. Save the prior control
  -- parameter so we can restore on exit. The valueParam keeps
  -- pointing at the live param so audio doesn't change.
  self._sceneSavedControlParam = self.fader:getControlParameter()
  self.fader:setTargetParameter(sceneTargetParam)
  self.fader:setControlParameter(sceneTargetParam)
  -- Optional visual cue: brighten the target marker, dim the
  -- value marker, etc. (use existing highlightTarget call)
  self.fader:highlightTarget()
end

function Fader:exitSceneMode()
  -- Restore the widget's pre-scene control parameter. Audio
  -- never changed during authoring; just the target marker did.
  if self._sceneSavedControlParam then
    self.fader:setControlParameter(self._sceneSavedControlParam)
    self.fader:setTargetParameter(self._sceneSavedControlParam)
    self._sceneSavedControlParam = nil
    self.fader:highlightValue()
  end
end

function Fader:getSceneTargetValue()
  -- Read the current target value (the scene's delta target).
  -- Called by Chain on exit to snapshot back into scene.deltas.
  return self.fader:getTargetParameter():target()
end

function Fader:getControlId()
  -- Stable identifier for the control within its unit, used as
  -- the scene.deltas[unitKey][controlId] key. Each ViewControl
  -- already has self.instanceName (the button name); reuse that.
  return self:getInstanceName()
end
```

Each delta-able control type implements the same four methods.
The Fader implementation above is the template; GainBias / Pitch
use the same shape with their respective fader widgets. Gate /
InputGate use comparator threshold params instead of fader value
params (one-line difference).

## Chain-side API

`Chain` (or `Chain.Root` specifically) gets two methods that walk
every unit's delta-able controls and call enterSceneMode /
exitSceneMode on each:

```lua
function Root:enterSceneAuthoring(sceneView, sceneIdx)
  local scene = sceneView:getScene(sceneIdx)
  if scene == nil then return end
  self.activeAuthoringScene  = scene
  self.activeAuthoringIdx    = sceneIdx
  self._sceneTargetParams    = {}  -- per (unitKey, ctrlId)

  for _, unit in ipairs(self:getAllUnits()) do
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.enterSceneMode then
        -- Build the per-scene target param. Initial value comes
        -- from the scene's existing delta if one exists; else
        -- from the control's current value (so re-dives reflect
        -- the same starting position).
        local currentVal  = control.fader:getValueParameter():target()
        local deltaVal    = scene:getDelta(unitKey, ctrlId) or currentVal
        local targetParam = app.Parameter(ctrlId .. "_scene", deltaVal)
        self._sceneTargetParams[unitKey] = self._sceneTargetParams[unitKey] or {}
        self._sceneTargetParams[unitKey][ctrlId] = targetParam
        control:enterSceneMode(targetParam)
      end
    end
  end
end

function Root:exitSceneAuthoring()
  if self.activeAuthoringScene == nil then return end
  for _, unit in ipairs(self:getAllUnits()) do
    local unitKey = unit:getInstanceKey()
    for ctrlId, control in pairs(unit.controls) do
      if control.exitSceneMode then
        local val = control:getSceneTargetValue()
        -- Only record as a delta if it differs from the live
        -- value (no point cluttering deltas with no-op targets).
        local baseVal = control.fader:getValueParameter():target()
        if math.abs(val - baseVal) > 1e-6 then
          self.activeAuthoringScene:setDelta(unitKey, ctrlId, val)
        else
          self.activeAuthoringScene:setDelta(unitKey, ctrlId, nil)
        end
        control:exitSceneMode()
      end
    end
  end
  self.activeAuthoringScene  = nil
  self.activeAuthoringIdx    = nil
  self._sceneTargetParams    = nil
end
```

`getAllUnits()` is a helper that flattens the chain's unit list
(including nested branches if applicable). Whether to recurse
into containers is an open question for phase 3b; lean toward
NO (only top-level units delta-able in v1) to keep behavior
predictable.

## Authoring view simplification

Phase 3a's `xroot/SceneView/Authoring.lua` becomes irrelevant —
the authoring view IS the chain's existing editContext, just
with delta-armed controls. The dive flow simplifies:

1. Performance.S3 → `Channels.enterSceneAuthoring(sceneIdx)`
2. ChannelGroup arms the chain (`chain:enterSceneAuthoring(...)`)
   AND switches active context to `editContext`.
3. User edits in the chain's normal edit view. Visual: each
   delta-able control shows value + target.
4. User hits UP at unit-row root, OR shift+HOME, OR CANCEL.
5. ChannelGroup catches it, calls `chain:exitSceneAuthoring()`,
   switches active context back to `sceneHoldContext`.

The phase-3a Authoring.lua placeholder stub gets deleted (or kept
as a fallback for when we want a non-edit-view authoring shell).

## Return-gesture interception

The chain's edit view doesn't currently intercept UP-at-root or
shift+HOME for scene-mode purposes. Phase 3a had its own
Authoring window catch those. With the mutate-in-place approach,
the chain's edit context now serves both purposes — we need to
add a guard so:

- When `chain.activeAuthoringScene` is set (we're in scene
  authoring), UP at root / shift+HOME / CANCEL all trigger
  `Channels.leaveSceneAuthoring`.
- When NOT in scene authoring, those keys behave as they always
  did.

Implementation: in Chain or Channels.Group, wrap the edit
context's UP / zero / cancel handlers with a scene-check
preamble. The chain edit view's existing handlers run only if
no scene is active.

## Sub display while in authoring

The chain's normal edit view uses its sub display for per-unit
context (control names, parameter values, etc.). In scene
authoring, that's still what the user wants to see PLUS a
persistent reminder of which scene they're editing.

Lightweight overlay: a single label at the top edge of the sub
display ("scene N") rendered at GRAY7, always present while
authoring. The unit's existing sub-display content sits below it.

Implementation: `chain:enterSceneAuthoring` adds the overlay
label to the editContext's sub display; `exitSceneAuthoring`
removes it.

## Open questions for implementation

1. **Container units (multi-out, presets).** Do scene deltas
   recurse into container chains? Lean NO for v1: only top-level
   chain controls participate. Container internals can be
   surfaced in v2 if the workflow needs it.
2. **Unit add/remove during scene authoring.** If the user inserts
   a unit while in scene authoring, the new unit's controls
   aren't armed. Either lock unit insertion in scene mode, or
   silently skip arming new units. Lean toward the latter
   (lock is annoying; silently skip is forgiving and consistent
   with the snapshot model).
3. **Sub-display overlay font / position.** A small label that
   doesn't crowd the per-unit context. Probably font 9 at top-
   right of sub display, GRAY7.
4. **Highlight value vs target.** The existing `highlightValue` /
   `highlightTarget` methods on app.Fader change which marker is
   brighter. In scene authoring we want target highlighted (the
   thing the user is editing). On exit, restore to value
   highlighted. Phase 3a's "highlight value" was the default in
   user-mode; should be fine.
5. **Crossfader live-preview.** Should the crossfader CV affect
   audio EVEN while authoring? Probably yes for parity with the
   performance experience. Defer to phase 4 (engine apply).

## Phased delivery

Five sub-tasks for 3b, each independently testable.

### 3b.1 — Chain.Root enter/exit scene authoring (no UI yet)

- [ ] Add `enterSceneAuthoring(sceneView, sceneIdx)` /
      `exitSceneAuthoring()` to xroot/Chain/Root.lua.
- [ ] Walk units, call `enterSceneMode` / `exitSceneMode` on
      controls that support it (initially: none — the per-control
      methods land in 3b.3).
- [ ] State tracking (activeAuthoringScene, _sceneTargetParams).
- [ ] Snapshot/capture math (only differs-from-base values become
      deltas).
- [ ] Bench: verify enter/exit can be called repeatedly without
      crashing even with no delta-able controls present.

### 3b.2 — Channels.Group dive routes through Chain.Root

- [ ] `ChannelGroup.enterSceneAuthoring(sceneIdx)` now:
      activates editContext + calls chain:enterSceneAuthoring.
- [ ] `ChannelGroup.leaveSceneAuthoring()` now: calls
      chain:exitSceneAuthoring + activates sceneHoldContext.
- [ ] Delete xroot/SceneView/Authoring.lua (no longer needed) +
      drop SceneView.getAuthoringView / authoringViews cache.
- [ ] Bench: dive S3 from Performance lands on the chain's edit
      view. Back paths (UP / shift+HOME / CANCEL) return to
      Performance.

### 3b.3 — Fader gets enterSceneMode / exitSceneMode / getSceneTargetValue

- [ ] Add the three methods to xroot/Unit/ViewControl/Fader.lua
      following the template above.
- [ ] Bench: dive into authoring on a chain containing a unit
      with Fader controls. Each Fader shows the target marker.
      Encoder turns move the target, not the live value.
      Exit + re-dive shows the same target persisted.

### 3b.4 — Extend to GainBias / Pitch / BranchMeter / Gate / InputGate

- [ ] Copy the Fader pattern into each of the other 5
      delta-able ViewControl classes. Each is a one-method
      addition with the same shape.
- [ ] Bench: dive on a chain mixing multiple unit / control
      types. Every control supporting scene mode shows target
      marker; others render unchanged.

### 3b.5 — Sub-display scene-name overlay + return-gesture guard

- [ ] Sub display label "scene N" added on enter, removed on
      exit. Positioned to not crowd existing per-unit sub-
      display content.
- [ ] UP / shift+HOME / CANCEL in chain edit view check
      `chain.activeAuthoringScene` and call
      `Channels.leaveSceneAuthoring` if set; else fall through
      to existing behavior.
- [ ] Bench: full scene-mode workflow on real chains, including
      multiple round-trips per scene and switching between
      scenes mid-session.

## Out of scope for 3b (deferred to 3c or 4)

- **Pin icon overlay on delta'd controls in normal user-mode.**
  Visual cue so users see which controls have ANY scene's
  delta. Phase 3c.
- **Live audio preview during authoring.** Today's mutate-in-place
  approach leaves audio at the live value (only the target marker
  changes). For preview, phase 4's engine apply needs to read
  the scene's target during authoring even when the crossfader is
  at 0.
- **Crossfader CV active during authoring.** Likely fine but
  needs explicit verification once phase 4 lands.
- **Unit add/remove handling.** Defer; v1 silently skips new
  units' arming, as noted in open questions.
