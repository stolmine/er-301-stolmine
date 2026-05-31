# Hold mode rework: Octatrack-style scenes

**Status:** brainstorm capture (2026-05-31). No engineering scope
locked. Source: a Discord conversation between Bram (crumb dinger)
and Carson about how hold mode could become a usable performance
surface instead of the under-used pinset-assignment chore it is now.

## Why we're rethinking hold mode

Hold mode today is the 301's nearest analogue to Elektron's scenes
(particularly the Octatrack's), but with the friction reversed:
the OT lets you hold a button and turn a knob to lock that value
into a scene, while the 301 requires a deliberate "assign to
pinset" gesture per parameter. Neither of us uses hold mode much
because of the setup cost.

The Octatrack's magic is gestural: **hold a scene button, turn the
knob you want to affect, done**. Later Elektron devices added
modulation matrices that can theoretically do similar work but
also fell into the "menu per source / destination / depth" trap
that nobody actually uses live. The 301 has the same risk if we
add a "modulation matrix" style surface; the win would come from
preserving the immediacy.

## Proposed model: mirror the user-mode interface in hold mode

Inside hold mode, present the **same edit surface the user sees in
user mode** (same chain, same units, same control row). Any
parameter the user touches while in hold mode records the new
value as a **delta from the base state** for the currently-active
scene. Exit hold mode and you're back to the base values.

This means a user already knows how to "author" a scene: they just
navigate to the parameter the normal way and turn the knob. No
"select source" / "select depth" menu trips. The delta-from-base
representation also means storage is small even with many scenes
(4 GB of memory makes this a non-issue).

## Scene selection

The harder design question is **how the user picks which scene is
active** during performance. Two angles considered:

**Crossfader-equivalent via CV input.** Any of the 301's CV inputs
(IN1-4 / A1-4) can stand in for the OT's crossfader. The signal
position blends between scene A and scene B. No hardware change
needed: the user wires whatever physical fader / sequencer output
they want into the input of their choice. Configure the input in
admin (same input-picker pattern we're proposing for the sequencer
external clock).

**Discrete scene selection in the UI.** One level above the
mirrored edit surface, present a list of scene slots. M-keys
select among them. When a slot is hovered, the sub display shows
"assign to A / assign to B" toggles so the user can decide which
side of the crossfader that slot occupies. Reassigning a slot to
A or B that already has an occupant just drops the previous one
(no confirmation prompt; live performance has no time for that).

Tension: **M-key as selector vs M-key as ingress**. Custom units
already use M-key tap to ENTER the unit (matching standard
view-navigation convention). The brainstorm leans toward
prioritizing scene SELECTION on M-key tap (since that's the
performance-time gesture) and putting "enter patcher for this
slot" on a sub-display ply (S-key) for authoring. The sub display
has three plies available, so one of them as "go to patcher" is
cheap.

shift+HOME (`zeroReleased`) could pull the user back up from the
mirrored edit view to the scene-selection list, matching the
"full reset / return to top" convention we just established in
the dense unit picker.

## What this gets us

- **Performance immediacy** roughly comparable to the OT: scroll
  to a scene with the encoder, tap to select, the cross-fader CV
  blends. Not quite as fast as the OT's dedicated buttons, but
  no hardware changes.
- **Scene count is arbitrary**, limited only by visible space. Add
  plies to the main display to scroll through more scenes.
- **No "P-Lock" mental model needed**. The user just navigates to
  the param they want to change with the gesture they already know.

## Locked decisions (resolved 2026-05-31)

1. **A/B blending semantics with base state.** Two scene slots
   are crossfade-active at a time (A and B). Base state is the
   neutral backing layer. Per-param resolution:
   - No scene assigned to either slot: crossfader is a no-op,
     params read from base.
   - Only A assigned: crossfader interpolates A's delta against
     base. Base occupies B's "position."
   - Only B assigned: symmetric.
   - Both A and B assigned: interpolate between A and B's deltas
     per param. Any param NOT delta'd in either scene reads from
     base (no per-param crossfade math needed for the untouched
     long tail).

   Multi-scene morph (3+ scenes blending at once) stays out of
   v1; A/B is sufficient and matches the gestural model.

2. **Linear interpolation.** For v1, the crossfader CV linearly
   blends A and B's delta values per param. Snap / s-curve /
   detent variants are admin-flag candidates for later.

3. **Delta-able controls = anything on a fader.** Use the
   firmware's existing distinction between control types:
   - **Delta-able:** continuous controls (knobs, faders),
     toggles, sub-display-only params in habitat (no UI-surface
     distinction from main-display params for delta tracking).
   - **NOT delta-able:** momentary gates, step lists (habitat L1
     grid / sequencer-style), file-path / title / structural
     selectors. Hardcode the blacklist; mods can opt in via
     metadata later if they have parameterizable controls outside
     the default-allowable set.

4. **Storage: deltas only.** No full state snapshots. Expected
   scale is ≤16 scenes, probably fewer. Flat map per scene
   keyed by `(unit-id, param-name) -> value` is enough; revisit
   if scene count grows or full sub-patch swap becomes a thing.

5. **Gesture split confirmed.** M-key in performance mode is
   ONLY for scene-slot selection. Ingress to authoring requires
   EITHER selecting a slot first AND then taking an explicit
   "edit" action, OR hovering over a slot to expose a
   "move to patcher" button on a sub-display ply. No hard
   mode-toggle; the discipline lives in the gesture split.

6. **Carry forward what makes sense from hold mode; rebuild the
   rest.** Most obvious carry-over: the **pin icon** that hold
   mode uses to mark pinned params should appear on delta'd
   params in scene authoring view, so the user sees at a glance
   what's been overridden. Pinsets themselves serve as the
   underlying storage layer (no migration surface needed for
   users with pre-existing pinset investment). Other surfaces
   build ground-up to the gesture / interpolation model above.

## Performance mode layout

- **M1 ply = CV input picker** (always). Lets the user pick
  which CV jack feeds the crossfader. Visual representation of
  "CV focus per slot" (which slot is currently weighted by the
  CV signal position) is TBD; defer to implementation.
- **M2-M6 plies = scene slots** (5 visible per page). With ≤16
  scenes expected, that's 3-4 pages of slots; navigation between
  pages via encoder scroll or shift+M-key, TBD during build.
- Slot ply shows scene name (user-assignable), an A / B chip if
  that slot is currently bound to one of the crossfader
  positions, and the "delta count" (number of params overridden
  vs base, useful for at-a-glance "is this scene full or
  sparse").

## Carson's caveat

> "This is the exact type of thing that when I am thinking about
> it conceptually in my brain I think I know what I want, but
> then as soon as my hands touch the thing I realize that my
> conception was all wrong. So I suspect this will just need to
> get felt out in the hands during development."

Translation: this needs an exploratory prototype, not a locked
spec. The doc captures the brainstorm so the next iteration
starts from a shared baseline rather than re-deriving the same
ideas.

## Out of scope for v1

- New hardware (button rows, dedicated crossfader). Lean on
  existing CV inputs.
- Modulation matrix surface. The "hold a knob, turn the dest" is
  the win; matrix UIs defeat the point.
- More than 2 simultaneous scenes blended by hardware control.
  Discrete N-scene selection via UI is fine; mixing more than 2
  at once is a different problem.

## Where this fits in the stolmine roadmap

Not blocking. The sequencer external clock work
(`docs/planning/sequencer-ext-clock.md`) is the immediate next
hardware-adjacent feature. Scene rework should land after the
picker work has stabilized in users' hands AND after Bram has
spent time with the current hold mode on real performances, so
we have a clearer sense of what hurts. Likely a v0.7.0-stolmine
.10.x candidate, post-9.3.0 release feedback.
