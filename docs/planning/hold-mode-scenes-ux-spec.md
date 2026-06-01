# Hold-Mode Scenes — UX Spec

Authoritative behavior contract for scene mode. Lives alongside the
per-phase planning docs as a single source of truth so we don't
re-derive the keybinds and lifecycle every time a new tweak comes
in. When something in the implementation disagrees with this doc,
update one to match the other; do not let both drift.

References: `hold-mode-scenes-phase-3b.md` (mutate-in-place
authoring), `hold-mode-scenes-phase-3c.md` (sub-chain recursion),
`hold-mode-scenes-phase-4.md` (engine apply), and the habitat
`planning/shift-handling.md` (shift convention).

## Settings flag

`Settings.get("sceneMode")` is `"off"` or `"on"`. Default `"off"`.
When off, the panel HOLD button opens the legacy PinView. When on,
HOLD opens the scene Performance view instead. Setting flip is
live (checked on every HOLD press).

## Mode transitions

Triggered from `ChannelGroup:setMode`:

- `setMode("hold")` with sceneMode on:
  1. `chain:getSceneView():enterPerformanceView()`
  2. `chain:engageSceneMorph()` (refresh base snapshots, build
     morpher items, add the scene task to AudioThread)
  3. activate sceneHoldContext (Performance is the top window)

- `setMode("edit")`:
  1. If in scene authoring, `chain:exitSceneAuthoring()` (capture
     deltas, restore widgets, rebuild morpher)
  2. `chain:disengageSceneMorph()` (remove the scene task, clear
     morpher items, release per-scene Parameters)
  3. activate editContext

- `setMode("hold")` while already in hold (= already in
  Performance OR in scene authoring):
  - If in scene authoring: `leaveSceneAuthoring()` (panel-button
    bounce back to Performance).
  - Otherwise: no-op.

## Performance view

A `Base.Window` (not a SpottedStrip). Six M-key columns:

```
M1   M2   M3   M4   M5   M6
[Fader]  S1  S2  S3  S4  S5    (slots populate left to right)
```

- **M1**: the crossfader weight control. A full-height `app.Fader`
  (`ply` x 64) bound to the chain's scene-cv `app.GainBias.Bias`
  parameter. Range bar to the right of the bias slot driven by an
  `app.MinMax` watching `gb.Out`.
- **M2..M6**: scene slots. `SlotControl` widgets, each a
  rounded transparent `TextPanel` (1px GRAY3 border, mirrors
  QuickSaver styling). Scene name centered on the body; small A/B
  chip overlay at the top-right.
- **Floating "+"**: at the first un-populated slot ply (right of
  the last scene, up to M6). Affordance for "tap M-key here to add
  a new scene." Hidden when all 5 slots are full.
- **Cursor box**: 1px white outline framing the selected ply at
  full height (y=0, h=64). Position tracks `cursorCol`.

### Cursor model

`self.cursorCol ∈ {1..6}`. Selection by:

- Encoder when M1 is unfocused: scrolls left/right between M1..M6.
- M-key tap: jumps to that column. Tap on the "+" ply creates a
  new scene and jumps to it.
- HOME: snaps to M1.

### Main and sub bouncing carets (revised 2026-06-01)

Two distinct cursor states, mutually exclusive: a downward "▼ this
ply is selected by navigation" caret above the ply, and a leftward
"▶ this control is focused for editing" caret on the focused
control. Same convention as the standard chain edit view: ▼ for
nav, ▶ for selection, never both at once.

Performance owns a tiny `app.Graphic` `navCaret` configured with
`setCursorOrientation(cursorDown)` and `setCursorPosition` set to
the X center of the current ply at Y=64 (top of the ply). The
GraphicContext's main cursor controller swaps between:

- `navCaret` → renders ▼ above the current ply. Used for slot
  columns (M2..M6) always, and for M1 when no readout is focused.
- `nil` (no main caret) → used for M1 when a readout is focused.
  The sub controller takes over with ▶ at the readout.

The sub controller still follows `m1FocusedReadout` -- nil when
nothing is focused (no sub caret), else the readout itself (which
has cursorRight orientation built in, so ▶ at its left edge).

Slot plies have no top-level controls to focus into, so they only
ever show the ▼ navigation caret.

Cursor controllers go through `Widget:setMainCursorController` /
`setSubCursorController`, which fire the context's
`onEncoderFocusChanged` to update the GraphicContext. Performance
is its own focused widget (`Window:getFocusedWidget` returns
`self` when no child has grabbed focus) so the fields on
Performance itself drive both contexts.

The C++ `Graphic` class gained `setCursorOrientation(int)` and
`setCursorPosition(int x, int y)` setters (the orientations are
the `CursorOrientation` enum int values: 0=cursorDown,
1=cursorUp, 2=cursorLeft, 3=cursorRight) so a plain Graphic can
host a cursor state without subclassing. Used here to make
`navCaret` work without writing a new C++ widget.

### M-key auto-focus (revised 2026-06-01)

Tapping **M1** moves the cursor to column 1 AND auto-focuses the
bias readout via `_setM1FocusedReadout(self.m1Bias)`. The user
can immediately turn the encoder to set the crossfader weight
without an additional S3 press. Tapping the M-key for an
occupied slot just moves the cursor (slots have no auto-focus
target).

## Focus / unfocus protocol (M1)

Follows the built-in `Unit.ViewControl.GainBias` /
`Unit.ViewControl.Fader` protocol. Focus is opt-in.

- Initial state on entry: `m1FocusedReadout = nil`. Sub display
  renders the GainBias-style layout but neither readout shows a
  caret. Encoder does not edit; it navigates the cursor.
- **S2 (unshifted)**: focus `m1Gain`. If already focused on gain,
  open the gain decimal keyboard. Calls `readout:save()` on entry
  so `cancel` has a snapshot.
- **S3 (unshifted)**: focus `m1Bias` (or open the bias decimal
  keyboard if already focused).
- **S2/S3 shifted**: open the corresponding decimal keyboard
  directly (matches stock GainBias).
- **Encoder (focused)**: `m1FocusedReadout:encoder(change, shifted,
  fine)`. `fine` comes from `m1GainEncoderState` when the gain
  readout is focused, else `self.encoderState`. Both states are
  toggled by DIAL_PRESS.
- **Encoder (unfocused)**: falls through to the navigation path.
  Cursor scrolls.
- **ZERO**: zeroes the focused readout (no-op when unfocused).
- **CANCEL**: `focusedReadout:restore()` (snap back to the value
  saved when focus entered). No-op when unfocused.
- **UP**: releases focus via `_setM1FocusedReadout(nil)`. Without
  focus, UP falls through to the inherited handler (the panel
  default — exits the context).
- **DIAL_PRESS**: toggles Fine/Coarse on the focused readout's
  encoder state.

## Slot S-keys (M2..M6 on an occupied slot)

Bindings are mirrored in the sub display labels so the user can
see what each press does before committing. Shift swaps the
labels and the action.

| Key | Unshifted | Shifted |
|-----|-----------|---------|
| S1  | toggle endpoint A on this slot | (unused) |
| S2  | toggle endpoint B on this slot | rename scene |
| S3  | enter authoring | delete scene (with confirmation) |
| M-key tap | move cursor here | — |
| Shift+M | delete scene (with confirmation) | — |

Toggle semantics (`_toggleEndpoint`):
- Pressing the role on a slot that already holds it unassigns.
- Pressing on a slot that holds the OTHER role transfers: clears
  the other side first to avoid the SceneView setters rejecting
  the assignment.
- Setting an endpoint releases the previous slot's claim (one
  slot per endpoint).

After every assignment change: `_rebuildSceneMorph()` so the
audio-side morpher items use the new endpoint Parameters.

### Slot sub display

```
scene N: <name> (A)         <- top-left status (chip if bound)

                            <- spacer
S1: *A / asgn A   S2: ...   <- SubButton labels, swap under shift
```

Unshifted labels:
- S1: `*A` if this slot already holds A, else `asgn A`
- S2: `*B` if this slot already holds B, else `asgn B`
- S3: `edit`

Shifted labels:
- S1: blank
- S2: `rename`
- S3: `delete`

## "+" placeholder

When `cursorCol == _plusCol()` (the first un-populated slot):

- Main display: floating `+` label centered in the ply.
- Sub status: "new scene -- tap M to create".
- SubButton labels: blank (no S-key bindings; user must use the
  M-key tap).

## Authoring

Entry via S3 on an occupied slot. Routes through
`Channels.enterSceneAuthoring(sceneIdx)`:

1. `chain:enterSceneAuthoring(sceneView, sceneIdx)` — walker
   visits every delta-able control (top-level units, branches,
   Custom-Unit interiors, MultiBand sub-patches) and calls
   `control:enterSceneMode(scene:getOrCreateParam(...))`. The
   scene Parameter is persistent; encoder writes land on it
   directly and the morpher (still engaged) reads it live every
   audio frame, so audio follows the encoder in real time.
2. `setActiveContext(editContext)` — the user lands in the
   chain's regular edit view. Subtitle "editing <scene name>"
   propagates to every reachable chain header.

### Lock during authoring

Structural edits are blocked everywhere in the chain tree:
- `Unit:showMenu` (delete / bypass / move / rename /
  preset-replace)
- `Header:doCommand` (S1/S2/S3 unit-header commands)
- `InsertControl` (insert + paste)
- `ChainBase:shiftReleased` (MarkMenu / cut / copy / paste)

Each gated callsite consults `chain:getRootChain():
rejectSceneAuthoringEdit()`, which flashes "Locked while editing
scene." and returns `true`.

### Egress (revised 2026-06-01)

From the chain edit view during authoring, returning to
Performance:
- **HOLD** button (panel): special-cased in `ChannelGroup.setMode`
  to call `leaveSceneAuthoring` instead of no-op'ing.
- **shift+UP**: routes through `Channels.leaveSceneAuthoring`.
  Replaces the previous shift+HOME (zeroReleased) binding so
  ZERO can do its normal "snap focused readout to 0" job inside
  authoring without surprising the user.
- **CANCEL**: also routes through `Channels.leaveSceneAuthoring`.
  CANCEL has no other meaning during authoring (structural edits
  are locked, and CANCEL on a readout is owned by the readout
  itself which handles it before bubbling up here).

`leaveSceneAuthoring` calls `chain:exitSceneAuthoring` (which
captures deltas, drops the persistent param for any control whose
target now matches base, restores widgets, rebuilds the morpher)
then activates `sceneHoldContext`.

`setMode("edit")` is also a valid egress path; safety code in
`ChannelGroup.setMode` calls `exitSceneAuthoring` + `disengageSceneMorph`
in order before activating editContext, so the user can't strand
the chain with armed controls.

## Crossfader (revised 2026-06-01)

- `sceneView:getCrossfaderA()` / `getCrossfaderB()` return either
  a 1-based scene index or `0` ("base" sentinel).
- The M1 bias slider is a bipolar `LinearDialMap(-1, +1)` with
  zero at the midpoint. **+1 = full scene A**, **-1 = full
  scene B**, **0 = 50/50 blend**.
- Weight is the `mWeight` Parameter on the chain's `ParamSetMorph`,
  but it's stored in the `[0, 1]` domain internally (matching the
  legacy PinView path). `ParamSetMorph::process()` remaps the
  bipolar CV signal at audio rate via `weight = (1 - cv) * 0.5`
  before `hardSet`ting `mWeight`.
- Linear blend at the apply step:
  `audio = (1-w) * sceneA_param + w * sceneB_param`. Combined
  with the CV remap that puts cv=+1 at w=0 and cv=-1 at w=1, the
  net effect is "cv=+1 → audio sits on sceneA".
- An unconnected CV inlet falls through to cv=0 → w=0.5, i.e. a
  fixed 50/50 blend until the user wires a source. The bias
  knob then doesn't drive audio unless its modulation is also
  wired -- consistent with how `app.GainBias` produces nonzero
  output at a nonzero bias regardless of input.
- Per delta-able control, the morpher Item references the scene's
  persistent Parameter for that control IF the scene has a delta,
  else the base Parameter. Rebuild triggers:
  - Crossfader A or B reassignment (Performance S1/S2 toggle).
  - Scene add / delete.
  - Authoring exit (new or pruned deltas may change which
    Parameter is bound).

## Scene-cv branch (M1 dive)

A `Chain.Branch` wrapping the scene-cv GainBias's `In` inlet,
owned by `Chain.Root._sceneCVBranch`. S1 on M1 calls `branch:show()`
which opens a normal chain Window — the user can insert any units
in there (External CV source, LFO, S&H, ...). Their outputs feed
`gb.In`, which the GainBias multiplies by gain and offsets by
bias, producing `gb.Out` which drives the morpher's `mCV`.

Layout in the branch is standard chain edit. Egress (UP, HOME)
goes back to Performance.

The branch's `pChain` is `start()`ed on engage and `stop()`ed on
disengage so units inside only process while scene mode is active.

## Data model

### Scene (`xroot/SceneView/Scene.lua`)

- `self.deltas[unitKey][ctrlId] -> float`: on-disk storage. Source
  of truth before any `Parameter`s have been instantiated for this
  scene.
- `self.params[unitKey][ctrlId] -> app.Parameter`: in-memory live
  state. Lazy. Created via `getOrCreateParam` at scene-authoring
  enter and at morpher build time. Persists until disengage.

`serialize()` syncs `params -> deltas` first, then writes the
deltas table. `deserialize()` loads deltas; params get lazily
rebuilt from those values on next engage.

### Chain.Root per-control base snapshots

`self._sceneBaseParams[unitKey][ctrlId] -> app.Parameter`. Lazy.
Refreshed via `hardSet(control:getSceneBaseValue())` at the start
of every `engageSceneMorph`, capturing the user's user-mode value
at the moment scene mode is entered. Used as the "no delta"
endpoint when a scene lacks a delta for that control.

Survives across engages (cheap; reused). Cleared on chain destroy
only.

### ParamSetMorph (xroot/od/objects/control/ParamSetMorph.{h,cpp})

Two Item variants in `mItems`:
- 2-arg `(target, endValue float)`: PinView legacy path. start
  cached at add-time from `target->target()`.
- 3-arg `(target, startParam, endParam)`: scene path. start and
  end are Parameter pointers; `apply()` reads `target()` on each
  live every frame. dB-domain conversion honored when the target
  has `mEnableDecibelMorph`.

`process()` reads `mCV.buffer()[FRAMELENGTH-1]`, clamps [0,1],
`hardSet(weight)`, calls `apply()`. mCV unconnected returns
`ZeroOutput.buffer()` so weight stays at 0 (full A) -- PinView's
morpher never connects mCV so its encoder-driven weight is
preserved.

The `mHasLiveItems` flag disables the (weight unchanged + no
update needed) short-circuit when any 3-arg item is present
(endpoints may move every frame).

## Persistence

What serializes (round-trips across quicksave):
- `SceneView`: scenes (name + deltas), crossfaderA, crossfaderB.
- Each scene's deltas (float map). Params get rebuilt from
  deltas on next engage.
- The chain's scene-cv branch contents (standard chain
  serialization).
- Scene-cv GainBias's Gain + Bias parameters (their values are
  saved via the normal Parameter serialization since both
  `enableSerialization()` is called in Performance.init).

What does not serialize:
- Per-control base Parameters (recaptured every engage).
- Performance view session state (cursorCol, m1FocusedReadout,
  shiftHeld).
- Morpher engagement state (re-engaged on next setMode("hold")).

## Constraints / invariants

- **Audio params are never written by the encoder.** Encoder
  writes go to scene Parameters; the morpher writes audio params
  via `softSet` at audio rate. This is the airlock that lets
  authoring-time edits be audible without polluting user-mode
  state when the crossfader weight is partial.
- **One slot per endpoint.** `SceneView:setCrossfaderA(idx)` /
  `setCrossfaderB(idx)` enforce this. Performance S1/S2 toggle
  guards before calling so an A->B transfer doesn't try to claim
  both.
- **Structural edits locked during authoring.** Scenes can't be
  added/removed and units can't be moved/deleted while a scene
  is being authored, so the morpher's bound Parameters can't be
  invalidated mid-edit.
- **HOLD button is the canonical egress** from scene mode -- it
  bounces between Performance and authoring, and any other mode
  press (USER / ENV / MOD) runs the disengage path.

## Habitat shift-handling alignment (revised 2026-06-01)

Performance is a `Base.Window`, not a Pattern A `Unit.ViewControl`,
but it now follows habitat Pattern A semantics for the
sub-display label toggle:

- `shiftPressed` sets `shiftHeld = true`, clears `shiftUsed`.
  Does NOT redraw -- holding shift alone does not preview
  anything.
- The `encoder` handler sets `shiftUsed = true` whenever the
  encoder turns while `shiftHeld`. This is habitat Decision 1 (B):
  any encoder touch during shift hold suppresses the toggle.
- `shiftReleased`: a clean tap (`shiftHeld and not shiftUsed`)
  flips `shiftMode`. `shiftMode` is the persistent label set.

The slot S-button labels and the M1 S2/S3 labels both follow
`shiftMode`, not `shiftHeld`. The bindings (rename / delete /
decimal keyboard / etc) trigger on the OR of the panel `shifted`
arg and the persistent `shiftMode` -- either route lands at the
same action so the user can choose tap-toggle or shift+S press
naturally.

Slot-level shift swap means:
- `shiftMode = false`: S1 toggle A, S2 toggle B, S3 edit.
- `shiftMode = true`: S1 unused, S2 rename, S3 delete.

M1-level shift swap means:
- `shiftMode = false`: S1 dive branch, S2 focus gain, S3 focus
  bias.
- `shiftMode = true`: S1 dive branch, S2 set gain (decimal kb),
  S3 set bias (decimal kb).

This makes the mode visible at all times (the labels reflect
what S1/S2/S3 will do right now) and matches the habitat
discipline of "tap = toggle, encoder during hold = no toggle".

## Implementation pointers

| File | Role |
|------|------|
| `xroot/SceneView/init.lua` | Per-chain SceneView container. Owns the scenes list + crossfader A/B assignments. |
| `xroot/SceneView/Scene.lua` | Per-scene state: deltas + persistent app.Parameters with lazy bridge. |
| `xroot/SceneView/Performance.lua` | The Window. Layout, cursor, S-keys, M1 fader, shift handlers, focus protocol. |
| `xroot/SceneView/SlotControl.lua` | Per-slot widget (panel + A/B chip). |
| `xroot/Chain/Root.lua` | enterSceneAuthoring + exitSceneAuthoring, scene morph lifecycle (`engageSceneMorph` / `disengageSceneMorph` / `rebuildSceneMorph`), base Parameter map, scene-cv GainBias + branch + MinMax range. |
| `xroot/Channels/Group.lua` | setMode wiring -- scene morph engages on hold-with-scene-mode-on, disengages on edit. |
| `xroot/Unit/ViewControl/*.lua` | Per-control scene API (`enterSceneMode` / `exitSceneMode` / `getSceneTargetValue` / `getSceneBaseValue` / `getSceneAudioParam`). |
| `od/objects/control/ParamSetMorph.{h,cpp}` | 3-Parameter Item variant + CV inlet + audio-rate process. |
| `xroot/Unit/init.lua` | `Unit:walkChildChains(callback)` for the recursive walker. |

## Test matrix (Performance view)

| # | Action | Expected |
|---|---|---|
| 1.1 | Enter Performance from user-edit | sub display shows M1 GainBias layout, m1FocusedReadout = nil (no caret) |
| 1.2 | Tap S3 on M1 | bias readout focused, caret left of bias, save() snapshot taken |
| 1.3 | Turn encoder | bias updates; audio responds via morpher (weight changes) |
| 1.4 | Press CANCEL | bias snaps back to pre-edit value |
| 1.5 | Press UP | bias unfocuses, caret disappears, encoder navigates again |
| 1.6 | Tap S2 (unfocused) | gain readout focused, encoder routes there |
| 1.7 | Tap S2 again (focused on gain) | gain decimal keyboard opens |
| 1.8 | Shift-hold + S2 | gain decimal keyboard opens (direct path) |
| 2.1 | Add a scene via "+" tap | new SlotControl rendered, cursor moves to it, sub display shows "scene 1: S1" |
| 2.2 | S1 on slot | scene becomes A, label changes to "*A" |
| 2.3 | S2 on same slot | scene transfers to B (A side released), labels "asgn A" + "*B" |
| 2.4 | S3 on slot | scene authoring dive, edit context active, subtitle "editing S1" |
| 2.5 | Edit a control + UP | authoring exits, return to Performance, scene now shows the delta as a stored value (morpher rebuilt) |
| 3.1 | Shift-hold on slot | sub display labels swap to "" / "rename" / "delete" |
| 3.2 | Shift+S2 on slot | rename keyboard opens |
| 3.3 | Shift+S3 on slot | delete confirmation dialog |
| 3.4 | Shift+M on occupied slot | same delete confirmation |
| 4.1 | S1 on M1 (dive into scene-cv) | branch chain Window opens, user can insert units |
| 4.2 | Insert an External CV unit, UP back | scope on M1 sub display now shows the CV; mod button reflects branch contents |
| 4.3 | Turn the CV (plug in a fast LFO) | M1 fader's range bar widens, weight modulates audibly |
| 5.1 | Press HOLD (panel) again | exits scene mode, returns to user-edit, morpher disengaged |
| 5.2 | Press HOLD from authoring | bounces back to Performance |
| 6.1 | Quicksave + reload | scenes restored from deltas, crossfader assignments preserved, branch contents reload, persistent params rebuilt lazily |

When something here disagrees with what the firmware does, fix
the disagreement and update both sides. This doc is meant to be
load-bearing.
