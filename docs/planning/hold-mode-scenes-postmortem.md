# Hold-mode scenes: bring-up postmortem (.10 → .16)

Phase 4 (engine apply / CV crossfader) shipped as `v0.7.0-stolmine.9.3.0.10` and went through six more dev tags before the modulated user-edit display behaved correctly on the bench. Each iteration peeled back one layer of a compound bug. This doc captures the arc so future work on the per-control state machine doesn't re-discover the same lessons.

## Summary of the bug arc

| Tag | Symptom user reported | Root cause we hit | Fix |
|-----|----------------------|-------------------|-----|
| .10 | Scene assignment shifted base values across mode toggles | Morpher's `softSet` was leaving audio params at the last weighted output. Re-engage captured corrupted values as new base. | Hard-restore audio on `disengageSceneMorph` + VEE blend so bias=0 → audio=base. |
| .11 | Crossfader didn't affect audio in user-edit | Morpher disengaged on `setMode("edit")`. | Architectural option C+D: morpher stays live across mode toggles, per-control `enterModulatedDisplay` swaps widgets so encoder writes go to baseParam. |
| .12 | Adding a scene pulled all controls to 0 | Units added after engage had `baseParam` at default 0 because they weren't in engage's snapshot walk. | `rebuildSceneMorph` defensively walks + arms modulated display for unarmed controls. |
| .13 | Base bias shown by line not box; scene-authoring state sticking; shift state sticks after delete | Lua-side `highlightValue()`/`highlightTarget()` calls added; per-slot shift reset on add/delete. | Per-control highlight cycle: modulated → highlightValue, scene-editing → highlightTarget, symmetric on exit. (But see .15 — the Lua calls were no-ops until then.) |
| .14 | Airlock break when units created after scene assignment; highlight stuck after authoring | `enterSceneAuthoring` walked controls calling `enterSceneMode`, which early-returns on `_modAudioParam == nil`. Late-added units never got armed, their widgets stayed bound to live audio, encoder writes hard-edited audio during authoring. Visual "stuck" was same root cause: those controls never went through any highlight transition. | Centralized arm helper `Chain.Root:_armControlModulated` + `:_armAllControlsModulated`. Engage / rebuild / authoring-entry all funnel through it. `exitSceneAuthoring` gated on `_sceneTargetParam` to avoid spurious 0-deltas. |
| .15 | Box vs line inversion still wrong; cursor follows the wrong indicator | `Fader::draw` derived all brightness, draw order, and cursor purely from `sceneActive = (target != value)`. The `mHighlightTarget` field existed and had setters, but the renderer ignored it. The .13 Lua calls had been no-ops the whole time. | Wire `mHighlightTarget` into `Fader::draw`: brightness, draw order, and cursor all flip with it. `sceneActive=false` collapses to legacy look unchanged. |
| .16 | Box doesn't move when encoder turns, even though readout numerically updates | `baseParam` is a free-floating `app.Parameter()` — no Object owns it, so `Parameter::update()` never ticks. `Readout::encoder` writes via `softSet` which sets `mTarget` and starts a ramp but defers `mValue` to update calls. `Fader::draw` was reading `mpValueParameter->value()` for the box → frozen `mValue`. | When `sceneActive`, read `mpValueParameter->target()` instead of `value()`. Legacy `target == value` path still reads `value()` for smoothing. |

## Lessons distilled

### 1. Free-floating `app.Parameter()` has frozen `.value()`

A Parameter not owned by an Object never has `update()` called on it. `softSet` writes `mTarget` and schedules a ramp via `mStep`/`mCount`, but `mValue` only advances inside `update()`. Without ticks, `mValue` stays at the last `hardSet` value forever.

Widget reads of `.value()` (Fader box, MiniScope value-probe, anything reading current vs target) will appear stuck while `target()` is moving. Readout-based widgets that show `target()` will look alive, masking the bug for as long as you only check readouts.

**For future free-floating Parameters in this codebase:** either use `hardSet` everywhere (instant, no ramp), arrange for an owning Object to call `update()`, or fix the render path to read `target()`. We chose the third for Fader since the box-in-modulated-mode is semantically "user set point" and shouldn't smooth.

### 2. A Lua-callable C++ setter is not guaranteed to be read in render code

`app.Fader::highlightValue()` and `highlightTarget()` existed as setters that flipped `mHighlightTarget`. But `Fader::draw` derived everything from `sceneActive` and ignored `mHighlightTarget` entirely. The setters had no effect on rendering until `.15`.

Setters can predate or postdate their consumers. Before adding Lua calls to a C++ widget setter, grep the C++ source for actual *reads* of the field that setter modifies. Same applies to Lua-side flags: a `self._someFlag = true` that no draw/event code consults is dead.

### 3. Centralize idempotent state transitions for multi-entry state machines

Three call sites (`engageSceneMorph`, `rebuildSceneMorph`, `enterSceneAuthoring`) all needed to ensure every delta-able control was in modulated display before proceeding. They each had a slightly different copy of the "snapshot base + enterModulatedDisplay" walker. The third forgot it. That was `.14`'s airlock break.

`Chain.Root:_armControlModulated(unitKey, ctrlId, control)` is now the single idempotent helper; `:_armAllControlsModulated()` is the walk-and-arm wrapper. All three call sites route through it. Any future scene operation that crosses the "control must be armed" boundary should funnel through `_armAllControlsModulated` first.

### 4. Compound symptoms are common in UI state-machine bugs

The user's `.14`/`.15`/`.16` reports each looked like single symptoms but each had multiple co-located causes. "Box doesn't move when I turn the encoder" was *three* bugs stacked:

1. The Lua highlight calls had been no-ops, so brightness/draw-order/cursor were all on the wrong indicator.
2. The widget swap to `baseParam` was correct; the encoder was writing to base.
3. But `baseParam.value()` was frozen because nothing called `update()` on a free-floating Parameter.

Each layer hid the next. Don't conclude a fix is complete based on partial symptom relief — keep peeling until the user reports clean behavior, and expect that the symptom of layer N+1 was masked by layer N.

## Architecture quick-reference (post-`.16`)

Three-state per-control machine:

```
  Normal:    setParameter(audio)    -- value=target=control=audio
              ↓ Chain.Root._armControlModulated()
  Modulated: setValueParameter(base)
             setTargetParameter(audio)
             setControlParameter(base)
             highlightValue()       -- box bright on top, cursor on box
              ↓ enterSceneMode(sceneTargetParam)
  Editing:   setTargetParameter(sceneTargetParam)
             setControlParameter(sceneTargetParam)
             highlightTarget()      -- line bright on top, cursor on line
```

Box position in modulated/editing mode reads `valueParam->target()` (not `value()`). Line position reads `targetParam->target()` everywhere. Cursor follows the bright indicator.

`Chain.Root:_armAllControlsModulated()` is the single choke point for arming. Engage / rebuild / authoring-entry all route through it. `enterSceneMode` early-returns on `_modAudioParam == nil` — the arm step is the explicit pre-condition.

`exitSceneAuthoring` gates per-control delta capture on `control._sceneTargetParam` being non-nil so any control that didn't actually enter editing won't pollute the scene with a spurious 0-delta from `getSceneTargetValue`'s fallback-to-0.

## What's deliberately not done

- **Auto-arm on chain insertion via `contentChanged` subscription.** The root chain could subscribe to its own `contentChanged` signal and arm new units immediately, but sub-chain inserts emit on the branch, not root — so we'd need per-branch subscription bookkeeping. Punted until a bench case proves it necessary. The three scene-op choke points cover every reported scenario; the only visual hole is "new unit in user-edit looks wrong until next scene op," which nobody's hit yet.
- **`Parameter::update()` ticks for `baseParam`.** Could be added by registering baseParams with a dummy Object that runs in the scene task. Not needed once Fader::draw reads `target()` for the box.
