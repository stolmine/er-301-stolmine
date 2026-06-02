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

### Incorporate sub-display edits into scene authoring

Original impl plan (`hold-mode-scenes-impl.md:107`,
`hold-mode-scenes.md:107-116`) defines delta-able as *every*
continuous Parameter the user can edit, including sub-display-only
params on habitat units. Current phase 3b implementation only
covers ONE Parameter per ViewControl (the main fader's value param).
Sub-display readouts that bind to a *separate* Parameter on the same
control (GainBias's gain, habitat-unit-style multi-knob layouts) are
not scene-routable — encoder writes on them bypass scenes
entirely.

**Goal**: extend the per-control state machine so every Parameter
a ViewControl exposes via an editable Readout participates in
scene authoring and the crossfade.

Detailed plan to be written before implementation. Scope and
schema-migration story matter enough to warrant a separate doc.
See `docs/planning/hold-mode-scenes-sub-display-routing.md`.

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
| `.24` | Slot scroll easing (matches SpottedStrip 0.20 lerp / 2 px snap) | `8a90339` |
| `.25` | Performance refactor: Window → SpottedStrip + per-scene Controls | `a4a375c` |
| `.26` | M1 fader / sub readout ▶ carets restored + indicator/chip/plus glyph centering anchored on TextPanel visual center | `99eb948` |
| `.27` | Crossfade switched from tri-state VEE (through-zero base) to bipolar linear A↔B. Escape from scene contribution is via unassigned (or empty-delta) endpoint; baseParam still fed in for that fallback. Indicators become opposing crescents that sum to 1. | `68dd914` |
