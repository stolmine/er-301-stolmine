# Hold-mode scenes: serialization audit

## Goal

Verify the scene system persists correctly through preset save +
load, end-to-end, on the current firmware. Cover the corner cases
the bench checklist hasn't yet hit, document where data lives, and
ship any plumbing fixes that fall out.

Scope: only the scene-system serialization paths. The broader
quicksave / preset infrastructure is out of scope (it's been stable
since pre-scenes). Cross-firmware compat for the scene fields IS
in scope.

## What's known to get serialized

Reading the call graph from `Chain.Root.serialize` down:

```
Chain.Root:serialize
  └── t.sceneView = self.sceneView:serialize()       <-- if sceneView created
       └── per-scene: scene:serialize()
            └── { name, deltas }                      <-- the actual scene data
       └── t.scenes = { ... }
       └── t.crossfaderA, t.crossfaderB               <-- assignment indices
       └── t.scenesEngaged?                            (need to verify)
       └── ...
```

The scene-CV branch (the M1 dive subchain containing user-inserted
CV source units) is a `Branch` object owned by `Chain.Root`. It
participates in the same chain-serialize path as any other branch
(via `_sceneCVBranch:serialize()` if/when called). Need to confirm
this is wired into `Chain.Root:serialize` correctly.

GainBias state (the M1 fader's bias + gain values) lives in the
`_sceneCVGainBias` Object's parameters. Standard `app.Parameter`
serialization handles those if `enableSerialization` was called
(yes, see Performance.lua `_biasParam:enableSerialization()` and
`_gainParam:enableSerialization()`).

What is NOT serialized (and shouldn't be):

- Live `app.Parameter` instances for scene targets / base
  snapshots. These are rebuilt on next engage from the float deltas.
- The morpher's `mWeight` runtime value (audio-thread state).
- Performance view's `scrollOffset` / cursor state (UI session).
- `isLockedForSceneAuthoring` flag, `activeAuthoringScene`
  (transient mode state).
- The M1 readout focus state.

## Methodology

### Phase A — Code audit

Read every serialize/deserialize call site for scene state. Map
out exactly what fields each level writes and reads. Build a table
of "field X is persisted from Y, restored to Z."

Files to read (in order):

1. `xroot/Chain/Root.lua`
   - `Root:serialize` — what does it write for the scene system?
   - `Root:deserialize` — does it correctly bootstrap SceneView
     when restoring? Lazy-create + deserialize order matters.
2. `xroot/SceneView/init.lua`
   - `SceneView:serialize` — schema of the dict.
   - `SceneView:deserialize` — does it restore A/B assignments?
     Iterate scenes in order? Handle missing fields?
3. `xroot/SceneView/Scene.lua`
   - `Scene:serialize` — `{ name, deltas }` only.
   - `Scene:deserialize` — clean reset to base shape.
4. `xroot/Channels/Group.lua`
   - Does ChannelGroup serialize any per-group scene state? (Like
     "this group is in HOLD mode" — probably not, since HOLD is
     panel-button driven, not persisted.)
5. `xroot/Channels/init.lua`
   - Any cross-group scene serialization?
6. `xroot/Application.lua` lines 35-50 and 459 (QuickSave / restore
   entry points) — confirm the persistence layer sees the full root.
7. `xroot/Persist/QuickSavePreset.lua`
   - Is the scene-CV branch reachable through this path? Look for
     how branches under root chains get walked.

For each persisted field, confirm:
- Saved on serialize.
- Restored on deserialize.
- No-op when absent (backward-compat).
- Survives a round-trip with no value drift.

### Phase B — Code-side smoke

Emu-driven smoke: load a known-good preset (one I construct by
hand or capture from bench) and verify the deserialize path
doesn't error. Confirm SceneView populates with the expected
counts, names, and delta values.

If feasible, write a tiny Lua test harness that constructs a
SceneView with synthetic deltas, calls serialize, prints the
table, calls deserialize on a fresh SceneView, and asserts
equality. Not strictly needed; bench testing covers it.

### Phase C — Bench checklist (the user does this)

Reuses the original TODO #50 list, expanded with corner cases
found in Phase A.

Baseline path (must pass):

- [ ] Build a chain with 2 scenes, each carrying deltas on 2+
      controls across 2+ units (one in root + one in a nested
      branch).
- [ ] Assign scene 1 → A, scene 2 → B. Save quickset.
- [ ] Reboot device. Load the quickset.
- [ ] Both scenes present with original names.
- [ ] A/B assignments restored.
- [ ] Delta count + values per scene match originals (open
      authoring on each to confirm).
- [ ] Bias-fill circle indicators on slots correctly mark the
      bound endpoints.
- [ ] Sweep M1 from B to A — audio interpolates exactly as
      pre-save (compare against a recorded reference if needed).
- [ ] Tap M1 → bias auto-focuses (the .21 gesture survived).
- [ ] Dive into M1's scene-CV subchain — any inserted CV
      units round-trip with their state.

Scale path:

- [ ] 8+ scenes. Reload, verify scroll viewport works through
      all of them, deltas intact.

Cross-firmware path:

- [ ] Save on stolmine. Try to load on vanilla.
- [ ] Expected: vanilla silently ignores the `sceneView` field;
      preset opens with base params at their saved values, no
      scene system active.
- [ ] Re-save on vanilla. Re-load on stolmine. Expected: scenes
      gone, but no crash; chain comes back as a pre-scenes
      preset would.

Backward compat:

- [ ] Load a pre-scenes preset (one from before this branch
      ever existed) on the current firmware. Expected: opens
      with no scenes, no errors, normal user-edit mode.
- [ ] Load a scenes preset that was saved by an earlier point
      on `feature/hold-mode-scenes` (pre-`.27` so under the
      tri-state VEE math). Now-bipolar morpher should still
      load the deltas correctly; behavior of the crossfade
      changes per `.27` but no data corruption.

Edge cases (Phase A may surface more):

- [ ] Save with SceneView created but zero scenes. Reload.
      Expected: same.
- [ ] Save with SceneView never engaged (lazy-created but
      never used). Reload. Expected: SceneView not serialized
      (per the existing guard `if self.sceneView then`).
- [ ] Save mid-authoring. Expected: structural-edit lock
      prevents save? Or save catches the post-edit state?
      Need to verify what happens.
- [ ] Save with A assigned but B unassigned. Reload. Expected:
      A restored, B at 0 (unassigned = base on that side).
- [ ] Save with both A and B unassigned. Reload. Expected:
      scenes preserved but no audible blend on M1 sweep.
- [ ] Rename a scene, save, reload. Expected: name persists.
- [ ] Duplicate a scene, save, reload. Expected: both copies
      present with the duplicated deltas intact.
- [ ] Delete a scene, save, reload. Expected: deletion
      persisted; remaining scenes correctly indexed.

Surprise cases worth probing:

- [ ] Saved scene references a unit that no longer exists at
      load time (e.g. user removed the unit between save and
      load). Expected: dangling deltas silently dropped on
      next engage? Or kept in deltas map for the case the
      user re-inserts a unit with the same instance key?
      `unitKey` is per-instance; restoring a deleted unit
      gives it a fresh key, so the orphan should be dropped.
      Verify the drop happens cleanly.
- [ ] Scene-CV branch has units inserted, then those units
      removed, then save. Expected: branch state reflects
      whatever's there; no orphan state.

### Phase D — Fixes for any gaps

If Phase A or C surfaces missing serialization, malformed
schema, or restore-time crashes, fix them. Each fix in its
own commit so the bench-test loop is granular.

Likely candidates if anything is wrong:
- Scene-CV branch not reached through `Chain.Root:serialize`.
- M1 GainBias gain/bias not surviving (forgot
  `enableSerialization` on one).
- A/B assignment indices not bounds-checked on restore
  (if user loads a preset that referenced scene 5 but only
  3 scenes exist now, crash or clamp?).

## Deliverable

1. Audit table: every persisted scene field, its source, its
   destination, its backward-compat behavior. Lives at the
   bottom of this doc once Phase A is done.
2. Fixes for any gaps found in Phase A (commits + tag bump).
3. Phase C bench checklist run on hardware; results recorded.
4. Final tag if all clean: bench-verified label on the current
   serialization shape.

## Risks

1. **Schema lock-in**: any change to what gets serialized now
   defines the on-disk format that future versions need to
   honor (or migrate). Once we ship past this branch, breaking
   the format requires migration. Phase A is the right time to
   reshape if needed.
2. **Cross-firmware reads**: vanilla firmware should treat the
   `sceneView` field as an unknown extension and ignore it.
   Verify on bench (we can't test in emu since stolmine is the
   only firmware here).
3. **Unit-instance key stability**: `unit:getInstanceKey()` is
   the join key for `deltas[unitKey]`. If the key changes
   across save/load for the same logical unit, deltas orphan.
   Probably already correct (instance keys are persisted with
   the unit) but worth confirming as part of Phase A.

## Revert path

The audit is non-destructive: reading code, building bench
fixtures. Any fixes that fall out land as small commits and
can be reverted independently.

If a fix turns out to need a schema migration (unlikely but
possible), we either:
- Ship the migration with a one-way upgrade on load (matches
  the Phase 1 sub-display-routing precedent that we just
  reverted, but that's fine for an actual fix).
- Or hold the change and document the deferred bug if the
  migration cost isn't worth the gain.

## Implementation order

1. **Phase A code audit** (1-2 hours). Read the four files
   listed above. Build the persisted-field table. Commit the
   audit table addition to this doc.
2. **Identify and ship any gaps** (variable). Each gap in its
   own commit.
3. **Tag a serialization-clean build** for bench testing.
4. **Phase C bench checklist** (user runs this; results captured
   in this doc or a sibling).
5. **Followup fixes** if bench surfaces additional gaps.

The audit might land in `.29` (no scene-system code changes),
or `.29+` if fixes accumulate.
