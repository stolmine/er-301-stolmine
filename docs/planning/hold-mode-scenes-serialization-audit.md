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

---

## Phase A findings (2026-06-02)

### Persisted-field table

| Field | Source | Destination | Backward-compat | Status |
|---|---|---|---|---|
| Per-chain root: `t.sceneView` | `Chain.Root:serialize` line 101-103 (only if `self.sceneView` exists) | `Chain.Root:deserialize` line 114-118 (lazy-creates SceneView via `getSceneView()`) | Missing field → SceneView not force-created. Preset opens normally without scenes. | ✓ |
| `sceneView.schemaVersion` | Hardcoded `1` in `SceneView:serialize` | Not consulted on `deserialize` | Reserved for future migrations | ✓ |
| `sceneView.sceneCount` | `#self.scenes` | Implicit (iterated via `ipairs(t.scenes)`) | Field is informational; deserialize uses `t.scenes` directly | ✓ |
| `sceneView.scenes[]` | Per-scene `Scene:serialize()` | `SceneView:deserialize` iterates with `kMaxScenes=16` cap | Missing → empty scenes list | ✓ |
| `sceneView.crossfaderA` / `B` | `self.crossfaderA / B` | Restored to `t.crossfader* or kEndpointBase` | Missing → defaults to 0 (base). Out-of-range clamped post-restore | ✓ |
| `sceneView.cvInput` (legacy) | Not written | Intentionally ignored on load (Phase 4 moved CV into the scene-cv branch) | Old saves' field silently dropped | ✓ |
| `scene.name` | `Scene:serialize` | `Scene:deserialize` writes only if present | Missing → preserves the default-name behavior | ✓ |
| `scene.deltas[unitKey][ctrlId]` | After `_syncDeltasFromParams()` | Direct copy of the map | Missing → empty deltas | ✓ |
| Unit instance keys | `Unit:serialize` line 396 | `Unit:deserialize` line 455-456 | Same key persists → scene deltas re-bind to the right unit on reload | ✓ |
| **`Chain.Root._sceneCVBranch` contents** | **NOT SERIALIZED** | **NOT RESTORED** | n/a | **GAP** |
| **`Chain.Root._sceneCVGainBias` bias + gain** | **NOT SERIALIZED** | **NOT RESTORED** | n/a | **GAP** |
| `Chain.Root._sceneMorph` mWeight | Not serialized (audio-thread runtime) | Re-initialized on engage | n/a | ✓ by design |
| `Chain.Root._sceneEngaged` flag | Not serialized | Re-engaged when user presses HOLD post-load | n/a | ✓ by design |
| Performance view UI state (scroll, cursor, focus) | Not serialized | Reset on view open | n/a | ✓ by design |

### Gaps found

**Gap 1 — Scene-CV branch contents lost.** When the user dives
into M1 from Performance and inserts CV-source units (LFO, S&H,
External, etc.), those units live in `Chain.Root._sceneCVBranch`,
a `Branch` object stored as a sibling-of-units on the root chain.
Nothing in the serialize pipeline reaches it:

- `Chain.Root:serialize` calls `Chain.serialize(self)` for the
  base data, plus `pinView` and `sceneView`. No mention of
  `_sceneCVBranch`.
- `Chain.serialize` only walks `self.units`, `self.channels`,
  `self.selection`. Branches owned by individual *units* are
  walked by `Unit:serialize` line 425-431; the scene-CV branch
  has no parent unit.

User impact: any patch wired into M1 dive (e.g. an LFO driving
the crossfade) is silently dropped on preset save / reload.

**Gap 2 — M1 bias / gain parameters lost.** `Chain.Root.
_sceneCVGainBias` is a free-standing `app.GainBias()` Object
whose Bias and Gain Parameters carry the M1 fader position. The
Performance view calls `enableSerialization()` on both, but
nothing actually walks them to write the values out. They get
re-built with defaults (bias=0, gain=1) on next `_getOrBuildSceneMorph`.

User impact: the crossfade position the user dialed in pre-save
isn't restored. Comes back at bias=0 (which is 50/50 A/B under
the .27 linear math).

Whether this is by design or a bug is a UX call. A performance
fader's "park" position arguably shouldn't persist (like a mixer
that zeros faders between sessions). But the `enableSerialization`
calls in Performance.lua suggest the original intent was to
persist. Persisting is the lower-surprise default; the user can
always clear the value.

### Proposed fix

One commit. Extend `Chain.Root:serialize` + `:deserialize` to
cover both gaps. Lazy-only: skip if the scene-CV pipeline hasn't
been built (most users don't engage scene mode).

```lua
function Root:serialize()
  local t = Chain.serialize(self)
  t.pinView = self.pinView:serialize()
  if self.sceneView then
    t.sceneView = self.sceneView:serialize()
  end
  -- Scene-CV pipeline (M1 dive contents + bias/gain). Only
  -- persisted if the user actually engaged scene mode (the
  -- pipeline is lazy-built by _getOrBuildSceneMorph).
  if self._sceneCVBranch then
    t.sceneCVBranch = self._sceneCVBranch:serialize()
  end
  if self._sceneCVGainBias then
    t.sceneCVParams = {
      bias = self._sceneCVGainBias:getParameter("Bias"):target(),
      gain = self._sceneCVGainBias:getParameter("Gain"):target(),
    }
  end
  return t
end

function Root:deserialize(t)
  Chain.deserialize(self, t)
  if t.pinView then self.pinView:deserialize(t.pinView)
  else self.pinView:removeAllPinSets() end
  if t.sceneView then self:getSceneView():deserialize(t.sceneView) end
  -- Force the scene-cv pipeline to exist before restoring its
  -- state. Same lazy-build entry point user-mode HOLD takes.
  if t.sceneCVBranch or t.sceneCVParams then
    self:_getOrBuildSceneMorph()
    if t.sceneCVBranch then
      self._sceneCVBranch:deserialize(t.sceneCVBranch)
    end
    if t.sceneCVParams then
      if t.sceneCVParams.bias then
        self._sceneCVGainBias:getParameter("Bias"):hardSet(t.sceneCVParams.bias)
      end
      if t.sceneCVParams.gain then
        self._sceneCVGainBias:getParameter("Gain"):hardSet(t.sceneCVParams.gain)
      end
    end
  end
end
```

Cross-firmware: vanilla firmware reads `t.sceneCVBranch` and
`t.sceneCVParams` as unknown fields and silently ignores them.
No breakage.

Forward-compat: old presets (pre-this-fix) lack both keys; the
guards skip both restore branches; the user has to re-create M1
dive contents. Acceptable since the feature branch hasn't shipped
to develop yet.

### What does NOT need fixing

- Scene's `self.params` table (live `app.Parameter` per scene).
  Explicit `self.params = {}` reset on `Scene:deserialize` is
  correct; getOrCreateParam rebuilds from `self.deltas` on next
  engage.
- Out-of-range A/B clamping. Already handled at
  `SceneView:deserialize` lines 159-164.
- Missing `t.scenes` etc. fields. Guarded with `if t.scenes then`.
- Schema version. Reserved for future use; no migration needed
  for the current shape.

### Phase A status

Audit complete. Fix shipped in `.29` (`cc587ea`): scene-CV branch
+ bias/gain serialize/deserialize. Subsequent fixes:

- `.30` `e696a3b`: save-while-engaged snapshot via `_sceneTask:lock`
  + `_hardRestoreAudioToBase`. CRASHED (lock blocked audio thread).
- `.31` `03ccee1`: replaced lock with `removeTask` / `addTask`.
  Avoided audio-thread block but exposed a forward-reference bug
  in `_hardRestoreAudioToBase` that was masked by the lock crash
  in `.30`.
- `.32` `b5a71e6`: fixed the forward-reference bug + moved
  `Crash.init()` to top of `Application.init` so init-time errors
  produce a real dialog. **Boot + quicksave round-trip clean on
  bench.**

## Phase C status

Bench round-trip on `.32`: **clean.** Save while scene mode
engaged, reload, scenes + A/B + M1 bias/gain + scene-CV branch
contents all restored without drift. The bake-in-base regression
from pre-`.30` is gone. No "reassign to refresh" workaround
needed.

Remaining items deferred to followups:

- 16-scene scroll round-trip (not tested with > 5 scenes yet).
- Cross-firmware round-trip (save on stolmine → load on vanilla
  → no crash; vanilla → stolmine → no crash).
- Pre-`.27` VEE-math preset migration (data shape unchanged so
  should just work, but worth a smoke).
- Orphan-unit case (delete a unit, save, reload — does the
  scene's dangling delta get dropped cleanly?).
