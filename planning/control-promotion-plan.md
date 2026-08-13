# Control promotion — implementation plan

*Spec for ledger item `promote-control-to-top-level`. Promote an inner control to a
macro on any ancestor unit in one gesture, preserving its value, its display and
its modulation.*

## CURRENT STATE (2026-08-13) — resume here

**Status: designed and reviewed, NOT implemented. No code written.** Nothing in
this plan has been built; the repo is untouched by it.

Three adversarial review passes against the source were run during design. Passes
1 and 2 each found real blockers (listed under the revision note below); pass 3
found only implementation sharpenings and returned **GO**. All four of pass 3's
findings are folded into the sections below, so this document is the single
source of truth — the review history is summarised here and does not need
re-deriving.

**Implementation order** (from pass 3, and the order to actually follow):

1. **Phase 1**, §4 — `scaling` into `customKeys` + serialization, forwarding via
   the customize path. Independent of everything else, testable against
   hand-built macros, improves manually built macros on its own. Commit separately.
2. **Discriminator + menu entry**, §2 and §6 — small, unblocks UI testing.
3. **Picker + inert-create/cancel**, §7, including the `branch:stop()` fix.
4. **Transplant**, §5, with the Chain-layer serialize pinned down.
5. **Scene clear**, §6, plus tests 9-11.

**Single riskiest step: 4, the transplant commit.** It is the only step whose
correctness depends simultaneously on post-queue drain order (posted source
restore, `Chain/init.lua:405-413`), on non-polymorphic dispatch (§5), and on
audio-frame interleaving (§5). Everything else is synchronous UI-thread work on
proven paths.

**Open question deliberately left for v2:** clamp forwarding (§4), Pitch support
(§2), and whether `canMove` should be honoured by placement (§8).

---

**Revision 4 (2026-08-13).** Folds in the four findings from review pass 3:
non-polymorphic serialize (§5), the `branch:stop()` cancel leak (§7), the
one-frame commit window (§5), and the discriminator self-consistency note (§2).

**Revision 3 (2026-08-12).** Two adversarial review passes against the source.
Rev 1 blockers: silence on scenes; Gate/Pitch declared promotable without a
bias/gain pair; serialize/deserialize transplant with no key handling. Rev 2
blockers: the scene remedy was one third of the required operation and collapsed
entirely under hold-mode engagement, and Rev 2's mandated key *regeneration* was
itself wrong — promotion is a move, not a duplicate. Rev 3 records the settled
decisions in §1; do not re-litigate them without cause.

## 0. Why this is harder than the flow it replaces

Building a macro by hand works because it has **no transparency obligation**. You
create a top-level control, wire the inner control to it, set the inner gain, and
tune the assembly by ear. Nothing has to match a prior state, so the bias/gain
arithmetic never surfaces as arithmetic.

Promotion is a **conversion**. It takes a setting the user already likes and must
preserve it. Every complication below follows from that difference.

Consequence to accept: hand-built and promoted macros have **different
semantics** and both will exist in the wild. Hand-built = inner holds the base
value, macro is a 0-to-1 controller adding on top. Promoted = macro holds the real
value in real units, inner is a pass-through. Promoted is the better arrangement
(the top-level control reads `440 Hz`, not `0.5`), but it will read as
inconsistent to anyone fluent in the old idiom.

## 1. Decisions (settled)

1. **v1 is GainBias-only, by exact-metatable match.** §2.
2. **Modulation is inherited**, whole-branch, not source-only. §3.
3. **No key regeneration.** Promotion is a move. Clear the origin branch *before*
   deserializing. §5.
4. **Refused during scene authoring AND while a scene is engaged.** §6.
5. **On commit, the promoted control's scene state is fully cleared** — delta,
   persistent param, and morph rebuild. §6.
6. **Nothing irreversible happens until ENTER.** The macro is created empty and
   unwired; CANCEL removes it. §7.
7. **No write-back on macro delete.** The origin collapses to 0. User's
   responsibility.
8. **Duplicates allowed**; repeat promotion chains. §9.
9. **Clamp forwarding deferred to v2** — it needs a C++ accessor. §4.
10. **The one-frame modulation delay is documented, not engineered around.** §9.

## 2. Scope: GainBias only, exact metatable

`out = bias + gain * in` is real for GainBias-class objects
(`od/objects/math/GainBias.cpp:36-56`, `od/objects/adapters/ParameterAdapter.cpp:31-40`).
It is not how the others work:

- `ControlBranch/Gate` is an `app.Comparator` — threshold plus
  gate/trigger/toggle modes (`Unit/ControlBranch/Gate.lua:14`). No bias/gain, and
  nonlinear: a toggle-mode origin re-fed from a toggle-mode macro toggles on the
  macro's *edges*, halving the rate.
- `ControlBranch/Pitch` is an `app.ConstantOffset` — offset only, no gain
  (`ControlBranch/Pitch.lua:14-19`). Clean v2 analogue: macro offset = O, origin
  offset = 0.

**The test must be exact-metatable, not type or class.** The Class system
deep-copies members into subclasses (`Base/Class.lua:36-49`) and there is no
`isInstanceOf`, so `control.type == "GainBias"` (`GainBias.lua:80`) is inherited
by every descendant, and a menu entry added to `GainBias:getFloatingMenuItems` is
inherited too. Instances take the class table as their metatable
(`Class.lua:80-86`), so:

```lua
getmetatable(control) == require "Unit.ViewControl.GainBias"
```

matches plain instances only. That is the correct line, not a compromise:

| habitat | count |
|---|---|
| plain `GainBias{}` instantiations | **509** |
| classes deriving from GainBias | 49 |

The 49 subclasses are exactly the ones with semantics that would break. Example:
`mi/assets/ModeSelector.lua` uses bias as a quantized mode index and swaps its
fader label to the mode name; promoting it snaps the origin's label to
`modeNames[0]` while the macro is a bare numeric fader.

**Self-consistency the chaining story depends on:** the macro controls promotion
creates are themselves plain `GainBias{}` (`ControlBranch/GainBias.lua:25-31`), so
a promoted macro remains eligible for further promotion. §8's chain requires this.

The entry must be **absent**, not greyed, on non-matching controls, and also
absent when there is **no eligible ancestor** (a promotable control on a top-level
unit, whose only container is its own unit).

## 3. Semantics

Origin at bias `B`, gain `G`, modulation branch contents `F`:

| | bias | gain | branch |
|---|---|---|---|
| macro (new, on the chosen ancestor) | `B` | `G` | `F`, transplanted whole |
| origin (now a follower) | `0` | `1` | emptied; input source = macro's output |

Transparency: `origin = 0 + 1 * macroOut = B + G*F(S)`.

Moving only the input source and leaving inserted units behind yields
`F(macroOut)` where the patch had `G*F(S)` — a different signal. Do not ship the
half-move.

Targets are **ancestors only**: the units containing the origin, and the units
containing those, to the topmost unit in the chain. The origin's own unit is
excluded. Any depth.

### What happens to the origin control (asked and settled 2026-08-13)

The origin is **not destroyed, but it is hollowed**. Be clear about which:

- **Preserved:** the control object, its name, its display attributes (units,
  map, precision), its position on the strip, its identity in presets and
  quicksaves. It remains usable as an offset on top of the macro, i.e. a
  per-instance trim.
- **Moved out of it:** its bias value, its gain value, and its whole modulation
  branch. It reads `0` afterwards, not `440 Hz`.

**A pure copy is not possible**, and this is forced by the signal graph rather
than chosen. The origin has exactly one modulation input (`Chain:setInputSource`
holds one source and releases the previous, `Chain/init.lua:188`). For the macro
to drive the origin at all it must occupy that input; once it does, the origin's
existing modulation has nowhere to live except on the macro, and the origin's bias
must go to 0 or the patch reads `B + macroOut ≈ 2B`. Every design in which the
macro drives the origin arrives here.

**The alternative that was considered and rejected:** macro bias 0 / gain `G`,
origin keeps bias `B` and gain 1, macro acts as an offset starting at zero. That
preserves the origin's value and its scene deltas (its bias is untouched, so most
of §6 evaporates), and the modulation still has to move up regardless. It was
rejected because the macro would then read `0` rather than the true value, and a
top-level control that reads in the parameter's own units is the main thing this
feature exists to provide. Confirmed 2026-08-13: **keep the current plan.**

There is no arrangement giving both, because the two controls sum and only one of
them can hold the value.

## 4. Phase 1 — attribute forwarding  [START HERE]

`ControlBranch/GainBias:init` constructs its view with only `button`,
`description`, `branch`, `gainbias`, `range` (`ControlBranch/GainBias.lua:25-31`),
forwarding none of `biasMap`, `gainMap`, `biasUnits`, `biasPrecision`, `scaling`,
`initialBias`, `initialGain`, all of which `ViewControl.GainBias` accepts
(`GainBias.lua:100-107, 199-203`). A promoted cutoff would be a bare 0-to-1 fader
driving a Hz parameter.

**Use the existing mechanism, don't build a parallel one.** `GainBias:customize()`
and its serialized `customizations` already round-trip name, description,
biasMin/Max/steps, gain map, units and precision (`GainBias.lua:261-328, 560-581`)
and the ControlEditor already edits them. What it genuinely lacks is **`scaling`**
(absent from `customKeys`, `GainBias.lua:25-42`), which is what makes an
exponential cutoff fader feel right.

Phase 1 is therefore: add `scaling` to `customKeys` and its serialization, then
have promotion snapshot the origin's customizable values and apply them to the
macro through the same path.

**Clamp is deferred to v2.** `ParameterAdapter::clamp(lower, upper)` is a setter;
`mLowerClamp` / `mUpperClamp` are private with no getters
(`od/objects/adapters/ParameterAdapter.h:28-36`), so the origin's clamp cannot be
read from Lua. Forwarding needs a C++ accessor plus SWIG regen. Consequence to
document in v1: the macro can display a value the origin silently refuses (macro
reads `-200 Hz`, actual is 0), because `process()` clamps
(`ParameterAdapter.cpp:37-38`) while `calculateProbeOutput` does not (`:66-106`).

Phase 1 is independent of everything else, testable against hand-built macros, and
improves every manually built macro even if the rest slips.

## 5. Phase 2 — the transplant

```
-- macro already exists, empty and unwired (see §7)
payload = Chain.serialize(origin.branch)           -- NON-polymorphic, see below
payload.instanceKey = nil                          -- strip top-level chain key
payload.selection   = nil                          -- cosmetic, free to drop
clear origin.branch                                -- FIRST. units removed, source released
Chain.deserialize(macro.branch, payload)           -- NON-polymorphic
macro.bias  = B ; macro.gain  = G                  -- BEFORE wiring
origin.gain = 0                                    -- dip, not double: see ordering below
origin.branch:setInputSource(1, macro:getOutputSource(1))
origin.bias = 0 ; origin.gain = 1
```

**The serialize/deserialize calls must be pinned to the Chain layer.** Writing
`origin.branch:serialize()` dispatches polymorphically, and when the origin is
*itself* a promoted or hand-built macro — the chaining case §8 supports —
`origin.branch` is a ControlBranch, so `ControlBranch:serialize`
(`Unit/ControlBranch/init.lua:59-66`) adds `t.control` (customizations, including
the name), `t.objects` (the adapter's bias/gain), `t.id` and `t.type`. Feeding
that to a polymorphic `deserialize` (`init.lua:68-76`) renames the macro to the
origin's name, bypassing `validateControlName`, and overwrites the macro's adapter
params outside the planned B/G assignment. Either call `Chain.serialize` /
`Chain.deserialize` explicitly, or strip `t.control` / `t.objects` / `t.id` /
`t.type` along with the key.

**One-frame window at commit.** `AudioThread.beginTransaction` batches task-list
changes only (`od/AudioThread.cpp:79-87`); it does not gate parameter writes, and
`Chain:clear`'s mute covers only the branch interior. So between wiring and the
final bias/gain assignment the audio thread can observe one frame of
`B + G*macroOut ≈ 2B`. Zeroing the origin's gain *before* wiring converts that
into a one-frame dip to 0 instead of a one-frame doubling — a click rather than a
pop, and the safer failure for an audio-path cutoff or level. Accept and document
it against §10's criterion; it is one frame at commit only, not a steady state.

**Do not regenerate instance keys.** Rev 2 mandated this by analogy with
`Persist/UnitPreset.lua:20`, but `Chain/Clipboard.lua:21-27` deliberately
*suppresses* regeneration for cut-paste: the codebase's **move** idiom preserves
keys so that key-referencing satellites survive. Promotion is a move.

Regenerating actively breaks things. Scene deltas are a flat map keyed by **unit**
instance key (`SceneView/Scene.lua:31-34`) and the scene walk descends through mod
branches and container interiors (`Chain/Root.lua:363-375, 431-435`;
`Unit:walkChildChains`, `Unit/init.lua:160-164`), so units *inside* the
transplanted branch can carry their own deltas. Regenerate and those deltas point
at dead keys forever — silent, permanent, and persisted.

Clearing the origin branch **before** deserializing means old and new keys never
coexist, so the nondeterministic `findByInstanceKey` binding
(`Source/init.lua:117-127`, unordered `pairs` walk at `Unit/init.lua:145-150`)
cannot occur. Only the payload's **top-level chain key** needs stripping, because
the origin branch itself survives still holding it and `Chain:deserialize` adopts
the payload's chain-level key (`Chain/init.lua:395-397`).

**Ordering and atomicity.** `Chain:deserialize` restores input sources in a
*posted* callback, not synchronously (`Chain/init.lua:405-413`), so the macro's
branch has units but no source until the UI loop drains posts. Bracket the whole
operation the way other structural edits do — `Chain:clear` mutes
(`Chain/init.lua:155-169`), deserialization brackets with
`AudioThread.beginTransaction` / `endTransaction` (`Chain/Base.lua:386, 421`) —
and set macro bias/gain **before** wiring, so no frame sees the origin driven by
an unconfigured adapter.

**Accepted collateral, to be documented:**

- Clearing the origin branch fires `onDeleteSource` for its units' output sources
  (`Unit/init.lua:707-711`), disconnecting any external chain fed from a unit
  inside the moved subtree. The transplanted copies do not inherit those
  consumers.
- **Pins on units inside the origin's branch are destroyed.** Clearing runs
  `ViewControl:onRemove -> chain:unpinControlFromAllPinSets`
  (`Unit/ViewControl/init.lua:389-400`); nothing re-pins the copies. This is
  distinct from the origin's own pin, §9.
- Serialize/deserialize builds **new unit instances**; fidelity is exactly
  quicksave-grade.
- `Chain:deserialize` silently drops the right input on a channel-count mismatch
  (`Chain/init.lua:404-405`). All ControlBranch types hardcode `channelCount = 1`;
  add a guard rather than rely on it.

## 6. Scene handling

Scene deltas are absolute target values keyed by `(unitKey, ctrlId)` against the
control's **bias** parameter (`Chain/Root.lua:500, 531-534`).

**Gate on both states.** `rejectSceneAuthoringEdit` (`Root.lua:46-56`) covers
authoring only. The harder case is **engaged**: while `_sceneEngaged`
(`Root.lua:958` sets, `:1049` clears) the morpher holds a Vee item per delta-able
control bound to a base snapshotted at engage time (`Root.lua:818-828, 872-894`)
and softSets the audio parameter every frame, so `origin.bias = 0` is overwritten
back to `B` on the next frame and the patch reads `≈2B`. Delta clearing does not
help; the base snapshot is the driver. v1 **refuses promotion in both states**.

**On commit, clear the promoted control's scene state completely.** Rev 2 called
`setDelta(unitKey, ctrlId, nil)` alone; that is one third of the operation.
`Scene:setDelta` touches only `self.deltas` (`Scene.lua:47-60`) — the persistent
Parameter lives in `self.params` and is untouched, and
`Scene:_syncDeltasFromParams` (`Scene.lua:118-125`) copies live params back into
deltas on serialize (`:134-142`), on `countDeltas`, and on disengage (`:129-132`),
so a cleared delta is **resurrected at the next quicksave**. The precedent,
`Root:exitSceneAuthoring` (`Root.lua:536-548, 579-581`), does three things. Do all
three:

1. `scene:setDelta(originUnitKey, originCtrlId, nil)`
2. clear `scene.params[originUnitKey][originCtrlId]`
3. `rebuildSceneMorph()`

for every scene (`sceneView:getScene(i)`, `Root.lua:869`), guarding for a nil
`sceneView`, which is lazily created (`Root.lua:26-31`).

Note step 3 is a **guaranteed no-op** at commit, because `rebuildSceneMorph`
early-returns unless engaged (`Root.lua:1064-1065`) and promotion is refused while
engaged. It is belt-and-braces, kept so the sequence stays correct if the engaged
refusal is ever relaxed. Do not "optimise" the refusal away on the grounds that
the rebuild handles it — it does not; the morpher's base snapshot is the driver,
not the delta.

The engaged refusal is load-bearing rather than paranoid: engagement persists when
the user leaves the Performance view back to the edit view (`Channels/Group.lua:148-152`,
"Disengage happens on chain destroy"), so the fan-out menu is genuinely reachable
while the morpher is softSetting every frame.

Result: that one control drops out of every scene; every other control's scene
data survives. Scoped, honest loss instead of silent corruption. Release-note it:
a scene that used to move that control will stop moving it.

## 7. Gesture, picker, placement — and the cancel boundary

**Order of operations, chosen so the irreversible work happens last:**

1. `promote` in the fan-out menu (`ViewControl:getFloatingMenuItems`,
   `Unit/ViewControl/init.lua:278`), subject to §2 and §6.
2. Ancestor picker. CANCEL here mutates nothing.
3. On target selection: create the macro **empty and unwired** via
   `addControlBranch` (`Section.lua:301`) with a name from
   `generateUniqueControlName` (`Section.lua:270`), then `placeControl` into the
   `expanded` view (`Section.lua:99`; `addControlBranch` does **not** place it —
   deserialize pairs the two at `Unit/init.lua:495`).
4. Placement: encoder moves it via the existing `moveControl`
   (`Section.lua:160-188`), ENTER commits.
5. **CANCEL during placement** → `branch:stop()` then `removeControlBranch`. The
   macro was inert — nothing wired, empty branch — so there is no audio
   consequence and the serialized patch is byte-identical afterwards (a dead
   branch fails the `isBuiltin` guard at `Unit/init.lua:427`).
6. **ENTER** → §5 transplant, §6 scene clear.

**The `branch:stop()` in step 5 is not optional.** Two pre-existing defects mean
`removeControlBranch` alone leaves live residue: it never calls `branch:stop()`,
and the only pChain task removal lives in `Chain:onStop`
(`Chain/init.lua:357-358`) — `ControlBranch:releaseResources` removes only the
ObjectList task (`Unit/ControlBranch/init.lua:49-53`). Separately,
`Section.lua:342` passes a branch *object* to `Unit:removeBranch(name)`
(`Unit/init.lua:285-290`), which indexes by name string, so the call is a silent
no-op and the dead branch stays in `unit.branches`, still findable by
`findByInstanceKey`. Stock behaviour that the Editor's delete path shares, but a
cancel/retry loop multiplies it: `generateUniqueControlName` reuses the freed
name, `addBranch` overwrites the stale entry, and the old pChain task is orphaned
on the audio thread permanently. It is a leak rather than a use-after-free
(`TaskScheduler::add` takes a refcount, `od/tasks/TaskScheduler.cpp:41-50`), but
it accumulates. Fixing `removeControlBranch` itself (stop, then
`removeBranch(id)`) is the better repair and benefits the existing delete path
too.

This replaces Rev 2's "nothing is mutated until ENTER commits placement", which
asserted a guarantee with no mechanism: `moveControl` repositions an
already-registered control, a real `GainBias` cannot be a placeholder (its init
hard-errors without `branch`/`gainbias`/`range`, `GainBias.lua:86-96`), and no
ghost-control class exists. Creating the macro inert gives a real rollback
boundary using APIs that already exist.

**Picker.** Valid targets are the ancestor path — a single path from the topmost
unit down to the origin, not a subtree. This is the opposite *direction* from
`ScopeView:loadUnitHelper` / `loadChainHelper` (`ScopeView.lua:39-80`), which
descend into children. Reuse ScopeView's nesting primitives
(`overview:startBranch` / `endBranch`) but emit only the ancestor path; excluding
the origin unit is dropping the last node. `LocalChooser` is the closer donor for
commit semantics (`choose(src)`, `LocalChooser.lua:388`).

**Placement UI.** `Unit.Editor` is a separate SpottedStrip screen entered from
`Unit/Section.lua:59` and built from `ItemHeader` proxies, so its screen is not
reusable in place — but its move *call* is: `doMoveControlLeft` /
`doMoveControlRight` (`Unit/Editor.lua:426, 441`) both call `moveControl`, and
that is what the encoder drives here.

## 8. Known, accepted behaviours

- **One frame of modulation delay.** Tasks run highest-priority-first with
  priority = depth (`od/AudioThread.cpp:47`); branches register at
  `unit.depth + 1` (`Section.lua:309`). **Not a regression** — the end state is
  structurally identical to a hand-built macro, which has the same delay. Versus
  no macro at all the modulation path gains one frame (~2.7 ms at 48k/128):
  inaudible for LFOs, real for audio-rate modulation through a branch.
- **The origin reads 0**; default readout is the bias parameter
  (`GainBias.lua:133-137`). `unitControlReadoutSource = "actual"` still shows the
  true value.
- **The origin's fader becomes an offset** on top of the macro. Useful as a trim.
- **A pin on the origin becomes a 0-centred trim** keeping its old label
  (`getPinControl` binds the bias Parameter at pin time, `GainBias.lua:219-232`).
- **Repeat promotion chains**: `macro1 -> macro2 -> origin`. The origin branch's
  serialized source references macro1's key, which lies outside the payload and
  resolves via `findByInstanceKey`. Depends on §5's no-regeneration rule.
- **`canMove` is declared on ten control classes and read nowhere.** If placement
  should honour `canMove = false`, that needs wiring up.

## 9. Test plan

Emu (`tests/emu/`). Several must pump the post queue before asserting, per §5.

1. Unmodulated promote: macro bias == origin's old bias; origin bias 0 / gain 1;
   value unchanged.
2. Modulated promote: source on the macro's branch; origin's branch input is the
   macro's output.
3. Units in the origin's branch: units moved, origin branch empty, signal
   unchanged.
4. Attribute forwarding: units, map, precision and **scaling** match.
5. Discriminator: a plain habitat `GainBias` offers promote; a `ModeSelector`-style
   subclass does not; a control with no eligible ancestor does not.
6. Ancestor-only: picker offers exactly the ancestors, never the origin or a
   sibling.
7. Double promotion: chain `macro1 -> macro2 -> origin`, macro1 still drives.
8. Instance keys unique across the tree after promotion.
9. Scenes: delta on the origin cleared **and still absent after a quicksave
   round-trip** (guards the `_syncDeltasFromParams` resurrection); deltas on other
   controls survive; promote refused while authoring; promote refused while
   engaged.
10. CANCEL at picker and at placement leaves the patch byte-identical.
11. Quicksave round-trip with a promoted macro.

Hardware bench: audible transparency on a real patch; repeated promote/delete for
resource lifecycle; a promoted control in a patch that also uses scenes.

## 10. Success criterion

Promoting a dialed-in plain GainBias control produces a top-level macro that reads
in the origin's own units, drives it one-to-one, carries its modulation, does not
change the sound at the moment of promotion, and leaves every scene except that
control's own entries intact.
