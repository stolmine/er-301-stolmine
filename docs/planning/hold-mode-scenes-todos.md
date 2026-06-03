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

### Sub-display params gated off in scene authoring (PARTIAL — gain gated in .33)

GainBias gain readout gated in `.33` (`setFocusedReadout` +
`doGainSet` both refuse + flash). Remaining gap: if the user
is ALREADY focused on gain when authoring starts (e.g. they
left the focus on gain in user-edit, then engaged scene mode),
the gate doesn't unfocus retroactively — they could still turn
the encoder. Mitigation: have `enterSceneMode` force-unfocus
non-routed slots when entering authoring. Small followup; rare
in practice.

Background:


Decision 2026-06-02: sub-display readouts that bind to a separate
Parameter from the main fader are **intentionally not** scene-routable.
Habitat units that want a sub-display knob to participate in scenes
should surface it as a standalone GainBias control in the unit's
expanded view; the existing single-Parameter scene model picks it up
there. We don't want to drive the schema, per-control state, and UI
complexity of multi-slot routing for the small payoff of keeping the
focused sub readout always-active.

What this work actually needs: a **guard** that prevents the focused
sub readout from writing to a Parameter that's outside the scene
system during authoring. Today the encoder will happily edit a
sub-display readout's underlying Parameter; the change persists past
authoring exit, bypassing the scene-target swap.

Options for the guard:

1. During authoring, intercept focus changes inside ViewControl so
   focusing a non-routed sub readout is either disallowed (silent
   no-op, maybe with a flash message) or downgraded to "view only"
   (focus highlights the readout but encoder is grabbed for nothing
   so writes don't land).
2. Soft variant: leave focus possible but route the encoder writes
   to a discarded Parameter so the user can spin without effect. Flash
   message + maybe a visual indicator that this readout isn't
   participating in the scene.
3. Hard variant: refuse focus entirely. The user has to leave authoring
   to edit non-scene sub params. Cleanest semantics but possibly
   surprising the first time it's hit.

Touch points: `Unit.ViewControl.GainBias` (gain readout focus path),
similar for any other ViewControl with multiple editable Parameters.
`Chain.Root.activeAuthoringScene` is already the "are we authoring?"
flag; the guard reads it on focus / encoder.

**See REJECTED plan**:
`docs/planning/hold-mode-scenes-sub-display-routing.md` records the
analysis of the alternative (extending the scene system to cover
sub-display params). Worth reading for context on why "gate, don't
extend" won.

---

### Subchain dive in scene authoring needs source-picker gating

Users need to dive into subchains during scene authoring so they can
edit delta-able params on units inside a sub-mod-branch (Mix unit's
sub levels, Custom Unit interior, etc.). The existing dive gesture
already works. **But** the source picker invoked inside the subchain
lets the user reassign the subchain's input source to a different
jack / global outlet — and that structural reassignment is a
non-delta-able change that survives authoring exit.

The structural-edit lock in `Chain.Root.rejectSceneAuthoringEdit`
already gates other patch-state operations (insert / paste / delete /
bypass / move / rename / preset-replace). The source picker path
needs equivalent gating: while authoring is active, the picker should
either refuse to open OR present only the current source as
non-editable.

Touch points: `xroot/Source/Chooser.lua` and `xroot/Source/Local.lua`
(wherever the source picker entry point is). Probably one
`Chain.Root.rejectSceneAuthoringEdit` call in the picker open path
that flashes the lock message and returns. Mirror the existing
gated-callsite pattern.

Companion: re-verify subchain dive doesn't surface other structural
gestures (move unit, delete unit, paste from clipboard) — those
already gate via `rejectSceneAuthoringEdit` but a fresh audit
confirms they all reach it.

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
| `.29` | Scene serialization gap fix: Chain.Root now persists scene-CV branch contents (M1 dive subchain units) + M1 bias/gain Parameters. Resolves two Phase A audit gaps. Cross-firmware safe (vanilla treats unknown keys as no-op). The `.28` slot was previously used for the rejected sub-display routing work; bumped to `.29` to keep dev-digit semantics. | `cc587ea` |
| `.30` | Save-while-engaged bug: serialize now snaps audio Params back to base (via `_sceneTask:lock` + `_hardRestoreAudioToBase`) before the unit-walk captures values. Without this, the morpher's last blend output was being persisted as the audio target, then re-engagement post-load snapshotted that *blended* value as the new base — baking scene contribution into the user's pre-scene base permanently. Shared helper refactored out of disengageSceneMorph. | `e696a3b` (hard crash on quicksave: lock blocks audio thread) |
| `.31` | Replace `_sceneTask:lock` with `removeTask` / `addTask` around the snap. `lock` enters a mutex the audio thread also tries to enter on every morpher pass; holding it across the whole unit-walk caused a watchdog kill on quicksave. `removeTask` just yanks the morpher off the scheduler for the snap window — no mutex contention. Same end behavior, audio thread doesn't block. | `03ccee1` |
| `.32` | Boot hardening. (1) Fixed forward-reference bug in `_hardRestoreAudioToBase` — was defined before `local function _walkAllUnits`, so the closure bound the nil global instead of the walker; every save/disengage with scene mode engaged crashed. (2) Moved `Crash.init()` from `Application.loop` to top of `Application.init` so init-time errors get the friendly dialog + crash.log entry instead of falling through to start.lua's silent emergency event loop. | `b5a71e6` |
| `.33` | GainBias gain readout gated during scene authoring. Gain isn't scene-routed (enterSceneMode swaps `self.bias` to the per-scene target but `self.gain` stays bound to the live audio Parameter); without the gate, focusing gain or opening the decimal keyboard for gain would silently bypass the scene system. Both `setFocusedReadout(self.gain)` and `doGainSet` now refuse + flash "Gain isn't scene-routed -- exit authoring to edit." | `aa7fd57` |
| `.34` | Subchain input source gated during scene authoring. InputControl spotReleased (which opens the SourceChooser) + subReleased(3) clear path both gate via the existing `_lockedDuringSceneAuthoring` / `rejectSceneAuthoringEdit` pattern -- same as EmptySection / InsertControl. The picker never opens; the user gets the "Locked while editing scene." flash up front. | `d7bc9b8` |
| `.35` | MonitorControl M1 insert + paste gates added. The leak was `MonitorControl.activateChooser` (called from M1 enterReleased and sub S3) plus the S1 paste path -- both let the user insert / paste at chain head during scene authoring. Same `_lockedDuringSceneAuthoring` helper mirroring EmptySection / InputControl. | `6f78f77` |
