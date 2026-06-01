# Scene crossfader staying active in user-edit mode

User request after the v0.7.0-stolmine.9.3.0.10 bench: the
crossfader's position should keep affecting audio when the user
is in user-edit mode, not just when they're in Performance (hold)
mode. But base biases should still show where the user actually
set them, with the morph contribution shown as a visual hint
("dog-ear on individual plies affected by scenes, illustrate
current delta'd position with the grey line in user-edit mode,
while base biases stay where users actually put them").

## What "scenes affect audio in user-edit" actually means

The user wants:

1. The morpher (`ParamSetMorph`) keeps running in user-edit. The
   audio path stays modulated by the current bias.
2. The user's encoder edits in user-edit go to the **base** value,
   not the morphed value. Encoder feel doesn't change just because
   a scene is active.
3. Each affected control's main display shows:
   - **Box** (hollow rectangle) at the base value — where the user
     set it.
   - **Grey line** at the actually-audible (morphed) value.
   - These can be at different positions when the bias is off
     center, illustrating the modulation offset.
4. A dog-ear on plies whose audio is currently being modulated by
   an active scene contribution (i.e. there's a non-zero offset).
5. The base value still survives a return to user-edit cleanly —
   no destructive shifting from past morpher writes (the
   v0.7.0-stolmine.9.3.0.10 hard-restore protected this; we
   shouldn't lose it).

## Why this is hard

Today the architecture has **one Parameter per control**, owned by
the audio engine, and the user encoder writes to it directly. The
morpher's `softSet` writes to that same Parameter while engaged;
disengage hard-restores it. There's no notion of "base value" vs
"actual audio value" as separate things.

Requirement 2 demands they be separate. The user's encoder write
needs to land on a Parameter that:
- Is *displayed* as "user's base" in user-edit (the hollow box).
- Is *not* directly read by the audio engine — the audio engine
  reads `base + scene_contribution`.
- Survives disengage / re-engage without drift, even though the
  morpher keeps running.

This is fundamentally a question of where to insert the "+
scene_contribution" sum in the audio path.

## Option A -- Modify the audio engine per control type

For every delta-able control (GainBias, Fader, Pitch, BranchMeter,
Gate, InputGate), add a parallel "scene offset" parameter that
the engine sums into the existing param read.

```
audio_value = bias.value() + sceneOffset.value()
```

Pros:
- Clean separation. User-edit reads bias; engine reads bias + offset.
- Morpher writes only to sceneOffset; never touches bias.
- Encoder edits to bias propagate naturally.

Cons:
- Engine-level edits per control type. C++ work in 6+ classes.
- Backwards compat: existing saves don't know about sceneOffset.
- For Pitch (octave + cents), summing in cents space is the
  semantic the user expects; in volts on the Offset object the
  unit is different. Each control needs its own summing logic.
- Big surface area.

## Option B -- Add a soft modulation layer to Parameter

Add `Parameter::mModulator` (a pointer to another Parameter) and
change `Parameter::value()` to return `mValue + (mModulator ?
mModulator->value() : 0)`. Audio engine reads as before; the sum
happens transparently.

Pros:
- One C++ change at the Parameter layer, propagates to every
  engine read.
- No per-control work.
- User-edit widget can read `mTarget` directly to display base,
  ignoring `mModulator`.

Cons:
- Changes the contract of `value()`. Some code might rely on
  `value()` returning exactly what was last set (e.g. parameter
  smoothing loops that read value() to compute next-step ramp).
  Need to audit every value() call site.
- Existing tools that round-trip values via target ↔ value could
  see drift.
- Adds a per-Parameter pointer field; small memory cost on every
  Parameter, even ones not modulated.

## Option C -- Swap widget bindings in scene-active mode

Keep the morpher destructively writing to audio params (as now).
But when scene mode is active (even in user-edit), the ViewControl
widgets rebind so the encoder writes to a NEW per-control "base"
Parameter, NOT the audio param. The morpher reads base + scene to
compute its softSet target.

```
user encoder -> control widget -> baseParam (user-set)
                                       |
                                       v
                                 [scene morpher reads baseParam +
                                  scene_contribution to compute
                                  audio param target]
                                       |
                                       v
                                  audio param (engine reads)
                                       |
                                       v
                                  user-edit Fader displays:
                                     box  = baseParam (user's set)
                                     line = audio param (actual)
```

Pros:
- No engine changes.
- Morpher mechanism unchanged.
- baseParam already exists (per chain in `_sceneBaseParams`).
- The Fader widget already has value/target separation we can
  drive: setValueParameter(baseParam), setTargetParameter(audio),
  setControlParameter(baseParam).
- Mirrors exactly the scene-authoring widget swap we already
  built in Phase 3b.

Cons:
- Each ViewControl needs an "enterUserEditModulated" / "exit"
  pair, parallel to the existing enterSceneMode / exitSceneMode.
  Per-control work, but it's a shape we've done before.
- The morpher runs continuously. When the user enters or exits
  scene mode the morpher stays scheduled; only the widget
  bindings change.
- Need to decide what "exit scene mode" means now (e.g. through
  a setting flip, or "clear A and B both"). Without a clean exit
  path the morpher stays alive forever; not ideal.

## Option D -- "Scene mode is always on" when sceneMode setting is on

Mode-toggle goes away. Once sceneMode is on:
- Morpher is engaged at boot / chain init.
- Performance view is just one of several places to interact with
  the same active morpher.
- User-edit always shows widgets bound to base + line at morphed.
- Scene authoring (S3 on a slot) still dives into chain edit but
  with the readout swapped to scene-target as today.

Pros:
- No engagement state machine. Less to reason about.
- Crossfader is always live. User can plug a CV and have it
  modulate audio regardless of which mode they're in.
- Matches a "mod source" mental model: scenes are a modulation
  source that runs continuously, like an LFO.

Cons:
- The previous "hold mode toggle" is now mostly a navigation
  shortcut into Performance view, not a "scenes are on" toggle.
- Disengagement path on chain destroy still needed.
- Heavier impact on existing chains that don't use scenes
  (morpher idling but always scheduled). Minimal CPU cost since
  process() is cheap, but worth measuring.

## Recommendation

**Option C** (widget swap) is the lightest path that gives the
requested behavior. It's the same shape as Phase 3b's enterSceneMode
widget swap, just applied at a different lifecycle boundary.

Pair it with **Option D** semantics (morpher runs continuously
while sceneMode setting is on, no engagement toggle). The "hold"
button becomes purely a UI navigation gesture into Performance,
not a power toggle on the morpher.

Under C+D combined:

- sceneMode = on at Settings: morpher built + scheduled, all
  delta-able widgets swap to baseParam-driven display, audio
  driven by morpher reading base + scene.
- sceneMode = off: legacy path. Morpher torn down. Widgets back
  to direct audio param. (Existing behavior.)
- Toggle between Performance view and user-edit: pure
  navigation, no engine state change.
- Scene authoring (S3 in Performance): dives into chain edit with
  the readout temporarily swapped to scene-target instead of
  base (existing 3b path). Morpher continues running so audio
  follows live as the user edits the scene target.

## Open design questions

1. **What happens when sceneMode is toggled off mid-session?** Hard-
   restore audio params from baseParam (we already have that path
   in disengageSceneMorph). User loses the morph contribution
   that was audible; that's fine because they asked to turn
   scene mode off.

2. **What does the dog-ear on a ply mean in user-edit?** Two
   possible semantics:
   - **Per-ply**: any control on that ply currently has a non-
     zero scene contribution. The dog-ear lights up.
   - **Per-control**: every delta-able control gets its own
     dog-ear (= 6 carets visible at once is noisy). Less useful.
   - **Whole-display**: dog-ear at top-right of main display
     means "scene mode is engaged and bias is nonzero." Already
     have this rendering for scene authoring; extend to "while
     bias is nonzero" rather than "while authoring."

3. **What's the grey line's interpretation when bias is zero?**
   Audio = base, so line at base = same y as box. Visually
   identical to user-edit-no-scene look. Good (no distraction
   when nothing is moving).

4. **What if base value is at extreme + scene value is at
   extreme + bias near full?** The morpher's blend output may
   exceed the param's intended range. Need to clamp at the
   softSet site or at the engine. Currently softSet doesn't
   clamp; the engine probably tolerates over-range. Worth
   verifying per control type.

5. **Sub-chain controls**: a control inside a Custom Unit's
   interior. Same rules apply (it gets a baseParam in
   _sceneBaseParams via the recursive walker). The widget swap
   for sub-chain controls must happen too.

6. **Performance view's M1 fader**: this is a special case.
   It's the bias control itself, not a delta-able audio param.
   Stays as it is (bound to the scene-cv GainBias.Bias). No
   widget swap needed.

7. **Pin/Mark interactions**: a pinned control's PinView fader
   would also need to know about the scene modulation overlay.
   Phase 3b broke pin mode for delta-able controls already (no
   one bench-tested it). Treat as out of scope here; pin + scene
   compatibility is a separate task.

## Sub-tasks if we choose C+D

5.1  ChainBase / SceneView: hoist morpher engage out of Performance-
     entry into chain init, gated on sceneMode setting. Remove
     `engageSceneMorph` from setMode("hold").
5.2  ChannelGroup.setMode("edit"): no longer disengages. Toggle is
     pure navigation.
5.3  ViewControl base: introduce enterModulatedDisplay /
     exitModulatedDisplay analogous to enterSceneMode. Per-control
     overrides: same six classes as Phase 3b/4.4 (Fader,
     BranchMeter, Pitch, GainBias, Gate, InputGate).
5.4  Chain.Root: when sceneMode flips on, walk + arm widgets via
     enterModulatedDisplay; when off, walk + exitModulatedDisplay.
5.5  Setting change listener: detect sceneMode flip live.
5.6  Dog-ear: extend ChainBase indicator to flash when bias is
     non-zero (= morph contributing), not just during authoring.
     Or: per-ply dog-ear on the SpottedStrip section. Pick during
     UI pass.
5.7  Bench: verify base survives encoder + scene authoring +
     morpher-running through various crossfader positions.

## What this does NOT solve

- The dog-ear/grey-line illustration is informational only. The
  user can't directly edit the morphed value; they can only
  influence it by editing base or moving the bias.
- Scene authoring still needs the per-scene Parameter the encoder
  writes to; that's separate from baseParam.
- Pin mode + scene modulation interaction is out of scope here.

## Decision needed

Choose architecture before implementation. Default recommendation
above is C+D combined. Alternatives: C with mode-toggle preserved
(scenes only active during hold), or A/B for cleaner separation
at higher implementation cost.
