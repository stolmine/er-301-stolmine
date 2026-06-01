# Hold-Mode Scenes — Phase 3c: Sub-Chain Recursion

Status: planning. Branch: `feature/hold-mode-scenes`. Predecessor:
phase 3b (commit `df73b05`). Successor: phase 4 (engine apply via
ParamSetMorph).

## Why this phase exists

3b made every delta-able ViewControl on the top-level chain
participate in scene authoring. Inside a modulation branch
(GainBias / BranchMeter / Pitch all expose `self.branch` via S1
dive), the contained units' controls are NOT armed: their encoder
edits write to live audio, bypassing the scene's delta map.

Result today: the user dives into a mod branch during scene
authoring, tweaks a control, leaves, and finds their change
persisted past scene exit — the opposite of the "scene as an
editable preset of values" model. This phase closes the gap by
recursing the enter/exit walk through every branch the unit
exposes, at any depth.

The 3b `df73b05` commit already documents this as the planned
follow-up.

## Verified facts

- `Unit.branches` (xroot/Unit/init.lua:40) is a name-keyed table of
  `Chain.Branch` instances, populated by `addMonoBranch` /
  `addStereoBranch` / `addBranch`. Iteration via `pairs`.
- `Branch:include(Chain)` (xroot/Chain/Branch.lua:8). Branches are
  fully Chain-like: support `length()`, `getUnit(i)`, etc.
- `Branch:getRootChain()` (xroot/Chain/Branch.lua:36) walks upward
  so `chain:getRootChain().activeAuthoringScene` is already correct
  from any depth. The 3b lock callsites (Unit:showMenu, Header:
  doCommand, InsertControl gates) keep working inside sub-chains
  without modification.
- Unit instance keys are unique across the whole RootChain (assigned
  on insert, persisted via `setInstanceKey`). The existing delta
  schema `deltas[unitInstanceKey][controlId]` is already chain-
  agnostic — no storage change needed.

## Architecture

### Walker

A single recursive walker on `Chain.Root`:

```lua
local function _walkAllUnits(chain, callback)
  for i = 1, chain:length() do
    local unit = chain:getUnit(i)
    if unit then
      callback(unit)
      if unit.branches then
        for _, branch in pairs(unit.branches) do
          _walkAllUnits(branch, callback)
        end
      end
    end
  end
end
```

The existing enter/exit loops in `Chain.Root` become two-liners
that call the walker with the per-unit body as the callback.

### Storage

No change. Each armed control already stores its delta under
`deltas[unit:getInstanceKey()][ctrlId]`. Instance keys are unique
across the whole root chain. Sub-chain units land in the same flat
table.

### Lock

`Root:rejectSceneAuthoringEdit` is reached from sub-chains via
`unit.chain:getRootChain()`. Already correct at Unit:showMenu and
Header:doCommand. Two gaps inside sub-chains still need closing:

  - `ChainBase:shiftReleased` — opens MarkMenu in a sub-chain. The
    3b Root override doesn't run when the user is inside a Patch.
    Move the gate down (override on `Patch` as well, or push the
    check into `ChainBase:shiftReleased` directly).
  - InsertControl in sub-chains already gates via
    `self:getWindow():getRootChain()` — verify that path works for
    `Patch` (Patch inherits ChainBase which is the Window).

### Visual indicator inside a sub-chain

Subtitle was set on the Root chain header (3b.5). When the user
dives into a Patch (sub-chain), the Patch's own title shows
instead and the "editing S2" cue disappears.

Option A: propagate the subtitle to every branch's chain on enter
(walk + setSubTitle on each). Simple, mirrors Root.

Option B: a separate header overlay sourced from
`getRootChain().activeAuthoringScene`. Single source of truth, no
walk.

Option A is the cheap path and matches the 3b pattern. The
existing `chain:setSubTitle` / `clearSubTitle` is already wired into
the chain header render.

### Egress from a sub-chain

Keep Patch's existing UP / HOME behavior (pop one level). Once the
user is back at Root, the 3b egress overrides (UP, shift+HOME,
CANCEL) take over and leave authoring. HOLD-button bounce is at the
Channels level and works from any depth.

Do NOT add a "leave authoring from any depth" override on Patch —
it would surprise users who just want to step back one level.

## Sub-tasks

### 3c.1 Walker + recursion

Pull `_walkAllUnits` into `xroot/Chain/Root.lua`. Refactor
`enterSceneAuthoring` / `exitSceneAuthoring` to use it. The
per-unit body is unchanged (instance-key + per-ctrlId arming).

### 3c.2 Subtitle propagation

On enter: walk all sub-chains (via the same walker, but acting on
chains not units — or a parallel `_walkAllChains`) and setSubTitle
with the same string. On exit: clearSubTitle on each.

Alternative if `_walkAllChains` is awkward: extend the per-unit
callback to call `setSubTitle` on each `unit.chain` it visits,
de-duped via a visited-set.

### 3c.3 MarkMenu lock inside sub-chains

Either:
  (a) Push the `rejectSceneAuthoringEdit` check into
      `ChainBase:shiftReleased` directly (touches more code paths
      but applies everywhere).
  (b) Mirror Root's override on `Patch`.

(a) is cleaner — the check is cheap and the lock semantics are
chain-tree-wide. Plus it removes the special-case Root override
added in `df73b05`. The Root override on `shiftReleased` can be
removed in the same commit.

### 3c.4 Verify branch-dive UX

Bench: enter authoring, dive into a GainBias branch, tweak the
contained unit's controls, leave authoring via HOLD bounce. The
tweaks should land in the scene's delta map and be reverted to the
base value on exit (since 4 isn't done yet, "reverted" means the
widget restores; the audio path still ran with the encoder values
during the session — that's expected until phase 4 wires
ParamSetMorph).

### 3c.5 Edge cases

  - Empty branches (no contained units). Walker handles trivially
    (length()=0).
  - Disabled / muted sub-chains. Walker still arms them; encoder
    edits are visible after restore even though audio is muted —
    same behavior as outside scene mode. Do not special-case.
  - Custom Units. Their inner chain hangs off branches like
    anything else. Should "just work" via the walker. Verify on
    the bench with a Custom Unit containing a Fader.
  - Re-entrant enter (sceneA armed, user dives, separately tries
    enter). Already guarded by `if self.activeAuthoringScene then
    return end` at the top of `enterSceneAuthoring`.

## Out of scope for 3c

- Pinned-icon overlay on delta'd controls in regular user mode.
  Tracked as 3d.
- Engine apply (live audio interpolation via ParamSetMorph) —
  phase 4.
- Crossfader CV→blend wiring — phase 4.
- Scene-mode-aware control highlighting in the Performance view
  (e.g., "this scene touches Reverb.Mix"). Tracked as 5
  (polish).

## Open questions

1. Does any unit type stash a child Chain somewhere other than
   `self.branches`? (e.g., a Multiple/Mixer "channels" table.)
   Spot-check Mixer / Container units before committing 3c.1.

2. If a Custom Unit's inner chain has its OWN units with branches,
   does `unit.branches` on the Custom Unit point at the chain that
   then contains those nested units? Verify the recursion crosses
   the Custom-Unit boundary cleanly.

3. Should the subtitle string change inside a sub-chain to convey
   "you're inside a branch of a scene-armed chain"? Probably not —
   the chain title already says e.g. "GainBias.branch" and the
   scene name in the subtitle is enough context.

## Implementation order

1. 3c.1 walker + recursive arm/disarm.
2. 3c.3 lock pushdown (MarkMenu inside sub-chains).
3. 3c.2 subtitle propagation.
4. 3c.4 bench verify with at least one mod-branch tweak.
5. 3c.5 edge-case sweep (Custom Unit, empty branch).

Each step ships as its own commit. After 3c.5, the feature branch
is ready for phase 4 (engine apply).
