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

### v1.1: CV-controllable A / B scene selection (3-ply layout)

Bench-feedback request from `shellfritsch` (post-`.37` Discord
2026-06-04). The current model has CV on the morph weight but no CV
on A / B scene assignment — manual chip taps are the only writer.
Teletype / sequencer / external CV can't drive scene selection.

**Direction (chosen):** keep A / B as separate concepts (don't
collapse to crumb's linear-sweep — losing any-two-scene parallel
mixing isn't worth it). Promote A and B to first-class controls
at M2 / M3 so they get their own CV input subchain, same way M1
already gets one for the morph weight.

**Layout (chosen):**

```
M1  M2  M3  M4  M5  M6
morph A  B  scene scene scene
            1     2     3   ... scroll for scenes 4..16
```

Three plies for the crossfader controls; bank shrinks from 5
visible to 3 visible. Scroll model extends naturally — the
existing per-scene `scrollOffset` keeps integer semantics over
the bank; M1-M3 don't participate in scroll.

**Semantics (chosen): bidirectional, "user decides" wins**

A and B become GainBias-style faders backed by their own scene-CV
subchain (same plumbing M1's morph weight uses). The fader's value
quantizes to a scene index (0 = unassigned/base, 1..N = scene N).
Two writers compete for the value:

- CV in the subchain (when patched) writes every frame.
- Manual tap on `asgn A` / `asgn B` on a scene's S-display (the
  existing 1.0 gesture) hard-sets the fader's value.

This matches the existing 301 convention everywhere else (any
fader: CV writes target, encoder writes target, last writer
wins). No new rules; users already understand the dynamic-CV-
dominates-static-manual story from every other CV-modulated
fader. The bank's S1/S2 chip taps stay as the manual override
path, so users with no CV patched have the same affordance as
1.0.

**Open implementation questions** (resolve during build):

- Quantize CV → discrete scene index vs allow continuous
  inter-scene blend on the A/B selector? Probably quantize
  (the morph fader still provides the continuous A↔B blend).
- Skip-include toggle per scene for CV reachability (a CV sweep
  through all 16 scenes is rarely musical without a skip mask).
  Could ship without it, add when bench shows it's needed.
- Visual treatment of A/B faders: vertical fader with index
  readout? Tick marks at each scene boundary? Adaptive labels
  showing the scene name at the current value (like Plaits)?
- Does A/B fader respect the SceneSlotIndicator math? The slot
  bias-fill indicator currently reads morph Weight; under the
  new model it'd also need to know which scene is currently A
  vs B (which now changes dynamically via CV).
- M1 morph dive currently has a single CV-source subchain.
  A and B will need their own subchains — that's three scene-CV
  branches per chain instead of one. Persistence path
  (`Chain.Root._sceneCVBranch` serialize/deserialize from .29+)
  generalizes to a `_sceneCVBranches` map keyed by role
  ("morph", "A", "B").

**Implementation order (sketch):**

1. Plan doc covering quantization decision, skip-include
   semantics, persistence schema change.
2. New `ASelectorControl` / `BSelectorControl` (or one generic
   `SceneSelectorControl` parameterized by role).
3. `Chain.Root._sceneCVBranches` map. Migrate `_sceneCVBranch`
   to be the morph role; add A and B roles.
4. SceneSlotControl: A/B chip display now driven by
   `morph._sceneCVGainBiasA.target()` and `B.target()` (or
   wherever the quantized index lands).
5. Bench iteration.
6. Skip-include toggle if needed.

**Defer:** until bench-validation of 1.0 settles for a few
weeks. The shellfritsch request is the strongest concrete signal,
but other requests may surface that change the layout calculus.

---

### Preserve scenes across stereo link / unlink

Today: stereo-link or unlink on a channel pair destroys the existing
Chain.Root objects and constructs new ones (per the broader
[Chain-Reference Invalidation on Stereo Link/Unlink](../../TODO.md)
TODO). Each chain's SceneView dies with it. If the user has scenes
authored and then accidentally toggles a link, their entire scene
bank is gone. Has to be reconstructed from scratch.

Goal: scenes survive the destroy/recreate cycle when topology
allows, with a clear story for the topology cases that can't map
cleanly.

The simple version that works most of the time:

1. Before the destroy, snapshot `SceneView:serialize()` from the
   doomed chain plus `_sceneCVBranch:serialize()` and the M1
   `bias` / `gain` Param values — the same shape `Chain.Root:serialize`
   already produces in `.29+`. Hold the snapshot on the
   `ChannelGroup` (which survives the chain swap, per
   `Channels/Group.lua`).
2. After the new chain is constructed and its units have settled
   into their new instance keys, replay the snapshot via
   `SceneView:deserialize` + scene-CV branch deserialize + bias /
   gain hardSet.
3. For unit instance keys that didn't survive (e.g. link merged
   two formerly-separate units, or unlink split a unit into one
   pair where only one side has the key), the corresponding delta
   entries either drop silently or — better — get logged so the
   user knows what was lost.

Hard cases worth thinking about:

- **Link of two chains each with their own scenes.** Whose scenes
  win? Probably the left chain's, with right's silently dropped
  (the right chain ceases to exist as a discrete entity). Could
  alternatively merge: keep left's scenes 1..N, append right's
  scenes 1..M as scenes N+1..N+M, but unit-key collision risk.
- **Unlink of a linked pair with shared scenes.** The single
  SceneView splits into two. Each new chain gets a copy. Deltas
  whose unitKey lives in one half of the split-apart units stay
  with that chain; deltas whose key lives in the other half get
  dropped from this chain (and added to the other chain's copy).
- **A/B assignment under split**: if scene 1 was A on the linked
  chain and lives on the left after split, scene 1 stays A on
  the left and is dropped from the right (or kept but unassigned).

Implementation hooks:

- `Channels.link` / `Channels.unlink` (the dispatch in
  `xroot/Channels/init.lua` lines ~34-87) are the natural snapshot
  + replay points.
- `ChannelGroup` already carries `Context` objects across mode
  toggles; adding a transient `lastSceneSnapshot` field on the
  group is the cheapest place to stash it.
- `Signal.weakRegister("channelsModified", ...)` is the pattern
  the broader Chain-Reference Invalidation TODO recommends — for
  scenes specifically, that's likely the wrong layer because
  we want to snapshot BEFORE destroy and replay AFTER construct,
  not just notify-and-reseed.
- Reuse the .29+ serialize/deserialize shape verbatim. Don't
  reinvent the schema.

Touch points: `Channels/init.lua`, `Channels/Group.lua`,
`Chain/Root.lua` (snapshot helpers), `SceneView/init.lua`. Plus
the [Chain-Reference Invalidation](../../TODO.md) item is
adjacent work — they could land together.

This is a longer-term project. The simple snapshot-and-replay
case (no topology surprises) is maybe a day. Handling the
merge / split cases cleanly is a separate planning pass.

---

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
| `.36` | GainBias gain gate uses standard `rejectSceneAuthoringEdit` so the user sees the same "Locked while editing scene." flash everywhere else structural writes are blocked. | `9a3c7f6` |
| `.37` | M1 fader user-facing labels renamed `xfade` / `X-fade` → `morph`; decimal-keyboard prompts updated from "Crossfader gain/bias." to "Morph gain/bias.". | `da2c5c7` |
