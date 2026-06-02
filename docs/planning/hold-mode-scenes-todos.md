# Hold-mode scenes: open TODOs + shipped log

Consolidated tracker for the hold-mode scenes feature
(`feature/hold-mode-scenes`). The repo-wide `TODO.md` points
here; do not duplicate items in both files.

Bench-stable at `v0.7.0-stolmine.9.3.0.20`. See
`hold-mode-scenes-postmortem.md` for the `.10 → .19` bring-up
arc and the three distilled lessons (free-floating Parameters,
SWIG render no-op flags, multi-entry state machines).

---

## Open

### Sub-display edits bypass scene authoring

During scene authoring the main-display fader is swapped to write
to the scene's target Parameter (`enterSceneMode` rebinds
`setControlParameter` + `setTargetParameter` to the scene target).
Sub-display readouts on non-delta-able ViewControls are not. A user
who navigates to the sub display and edits a value via the readout
encoder hard-writes the live audio Parameter, bypassing the scene
system entirely. The change persists outside authoring and can't be
cleared by "exit without saving" because the write never went
through the scene target.

**Approach**: route every sub-display readout through a scene target
by default. No per-control opt-in/opt-out flag; walk each
ViewControl's sub-display readouts during `enterSceneMode` and swap
each one's Parameter binding to a freshly created scene target. The
existing subchain walker already recurses through branches, so
coverage extends to nested habitat units (Plaits, Clouds, Warps)
without per-package work. No graphics changes needed; the readout
renders whatever Parameter it's pointed at.

**Constraint**: user must not be able to change actual input routing
to subchains during authoring. Structural-edit lock already in place
during authoring covers this; this work only touches Parameter
bindings on existing readouts, never chain topology.

**Touch points**: extend `enterSceneMode` / `exitSceneMode` on every
ViewControl (including currently-non-delta-able ones) to enumerate
their sub-display Readouts and swap each readout's parameter. Likely
needs a new ViewControl protocol method like
`getSubDisplayParameters()` returning `{ [ctrlSubId] = audioParam,
... }` so `Chain.Root` can create one scene target per sub-display
readout and swap them on enter/exit. Update `exitSceneAuthoring`'s
delta-capture walker to capture per-sub-id.

`xroot/Unit/ViewControl/GainBias.lua` already swaps `self.bias` (the
sub-display bias readout) but not `self.gain`. Decide whether gain
should also participate; if so, this generalizes naturally.

Companion: per-control sub-display delta indicator (small dog-ear
on the sub-display ply corner showing the readout has a stored
scene delta). Generalize the existing main-display
`_setSceneAuthoringIndicator` to take a position arg.

---

### Verify serialize / deserialize round-trip

Scene-system serialize/deserialize was wired in Phase 1 + 4.3 but
never bench-tested end-to-end past the `.10 → .20` state-machine,
delta-map, indicator, and viewport-scroll changes.

Hardware checklist:

- Build a chain with 2+ scenes, each carrying deltas on 2+ controls
  across 2+ units, including a nested branch.
- Assign scene 1 to A, scene 2 to B. Save quickset.
- Reboot device. Load the quickset. Confirm:
  - Both scenes present with original names.
  - Crossfader A/B assignments restored.
  - Delta count + delta values per scene match originals.
  - Bias-fill indicator drives correctly from the restored A/B.
  - Authoring entry on each restored scene shows the original
    delta'd controls highlighted.
  - Bias movement on M1 produces the same audio sweep as pre-save.
- More than 5 scenes: save with 8+, reload, confirm scroll viewport
  works and all scenes round-trip.
- Repeat after the sub-display-routing change ships so sub deltas
  also round-trip.
- Cross-firmware: save on stolmine, load on vanilla. Scenes should
  be gracefully ignored, base values preserved.
- Old-preset compat: load a pre-scenes preset on the current
  firmware. Should open with no scenes, no errors, normal user mode.

**Touch points**: `xroot/SceneView/init.lua` (SceneView
serialize/deserialize), `xroot/SceneView/Scene.lua` (per-scene
serialize), `xroot/Chain/Root.lua` (scene-cv branch serialize + base
param restore).

---

### Easing animation on slot scroll

Slot scrolling currently snaps instantly between viewport positions.
User-edit's section scroll uses an easing animation (the ply strip
slides smoothly across the screen over a few frames). Apply the
same to Performance view scrolling so the user perceives the slot
list as a continuous strip rather than a discrete page-flip. Helps
confirm that scrolling happened, especially when the new viewport
holds visually similar scene names.

**Touch points**: locate the chain-edit section animation mechanism
(likely `xroot/Chain/Section.lua` or `xroot/SpottedStrip.lua`),
apply pattern to `Performance.lua` slot rendering. Each slot's
TextPanel + indicator + chip may need to share an animated
horizontal-offset variable that interpolates across a few frames.

---

## Shipped

| Tag | Item | Commit |
|-----|------|--------|
| `.17` | Eliminate morph slew (hardSet in apply, three sites) | `de66fcd` |
| `.17` | Adaptive A/B labels at fader extremes | `de66fcd` |
| `.18` | Initial bias-fill circle indicator on slot plies | `cb71973` |
| `.19` | Indicator antialiasing + centering + Vee-mode pin + 6-16 scene scroll | `2d01c3d` |
| `.20` | Duplicate scene via S1 in slot shift display | `9d7312e` |
| `.21` | M1 auto-focuses bias on click (collapsed cycle) | `94237eb` |
| `.22` | "+" placeholder ply uses graphic glyph (two crossed lines) + TextPanel-stride centering | `759bf8c` |
| `.23` | System-settings confirmSceneDelete toggle gates the delete dialog | `07dde18` |
