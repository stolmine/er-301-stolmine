# Habitat mi mode-selector crash regression (2026-05-15)

> **CLOSED 2026-05-16. Firmware was innocent. Cause was habitat-side
> Cortex-A8 NEON codegen at `-O3 -ffast-math` in `eurorack/plaits/dsp/
> voice.cc::Render`.**
>
> **Fixed in mi 1.0.3.13** by inserting calls to an in-package
> `extern "C" __attribute__((noinline)) void mi_barrier_noop()` at
> the swap boundary. **Minimized in mi 1.0.3.14** to a SINGLE call
> at swap entry. **Clouds parity in mi 1.0.3.15.**
>
> 🚨 **ROOT-CAUSE UPDATE 2026-05-16 late evening**: the AAPCS-barrier
> "fix" was actually a MASKING WORKAROUND. The real cause is GCC
> `-ftree-vectorize` (default at `-O3`) emitting Cortex-A8-trapping
> NEON alignment hints. Re-attempting 2× OS work at mi 1.0.3.16
> crashed again at a different code site, confirming the AAPCS
> theory was incomplete. **Durably fixed at mi 1.0.3.18** with
> `-fno-tree-vectorize` appended LAST in CFLAGS for am335x. The
> AAPCS barrier remains in place as belt-and-suspenders. No
> firmware action needed.
>
> No firmware action required. The .53 → 9.1.0 bisect that suggested
> a firmware-side regression was misleading — the crash was always
> latent in mi codegen; what changed was something about the package
> install / SD state across the rollback session that caused it to
> begin manifesting. The `-noseq` diagnostic firmware tag is no
> longer needed (`662c15f` can be reverted on the firmware repo).
>
> **What was actually ruled out (firmware-side, all turned out to
> be red herrings since the bug was habitat-side):**
> - SequencerTask::process — ruled out
> - SequencerTask construction side-effects — ruled out by implication
> - od/objects/ ABI between 9.1.0 → .53 — unchanged, ruled out
>
> **Full bisect record and root-cause analysis:**
> See `er-301-habitat/planning/mi-mode-switch-aapcs-barrier-resolution.md`
> for the 1.0.3.5 → 1.0.3.13 sequence (8 versions, each isolating one
> hypothesis: layout, delay, compiler-reorder, DMB, FPSCR, external
> call). Memory: `feedback_neon_aapcs_call_barrier.md`.

---

## Original investigation (historical, superseded)

## Confirmed scope + the Rings-vs-Plaits/Clouds split

Mi-side audit of which units use which Lua selector helper:

| mi unit | Lua selector | Status |
|---|---|---|
| Plaits | `mi.EngineSelector` | CRASH |
| Rings | `mi.EngineSelector` | **WORKS** |
| Clouds | `mi.ModeSelector` | CRASH |
| Warps | `mi.AlgoSelector` | not yet tested |

Plaits AND Rings both use the SAME `EngineSelector` Lua helper,
yet only Plaits crashes. **The Lua selector class is not the
trigger.** Whatever differs between Rings and Plaits/Clouds at
the C++ / firmware-boundary level IS the trigger.

This rules out:
- Plaits-engine-specific hypotheses (algorithm function-pointer
  dispatch, six_op staggered render, etc.) — Clouds also crashes
- Lua selector code in mi — Rings uses the same helper as Plaits
- SequencerTask per-frame process — `.54-noseq` bisect rules it out

The bug is in firmware-side code that something Plaits + Clouds
do TRIGGERS but Rings doesn't.

## Suspect: arena re-init on mode/engine switch

**Plaits' engine-switch path** (`eurorack/plaits/dsp/voice.cc:129-146`):
```cpp
if (engine_index != previous_engine_index_ || reload_user_data_) {
  allocator_->Free();      // reset arena
  e->Init(allocator_);     // re-init new engine (re-allocates from arena)
  ...
}
```

This is a substantial in-place arena reset + re-allocation that
happens inside `Voice::Render` (called every audio frame).
**Clouds' mode-switch** likely does something equivalent in
`GranularProcessor::Prepare`.

**Rings' model-switch** — habitat-side hasn't audited this — is
likely structurally DIFFERENT. Possibly does NOT do an arena
re-init, or does it on a different code path (UI thread vs audio
thread).

**If the firmware-side bug is a memory-corruption / NaN-source /
buffer-overflow that's exposed by the arena re-init dance**, it
would manifest on Plaits + Clouds but not Rings.

## Symptom

mi-1.0.x (any recent build) loads cleanly on hardware running
`v0.7.0-stolmine.9.1.0.53`. Plaits unit plays its default engine.
**Crashes on engine-selector change** (e.g. switching from VA to
Plucked, or scrolling the Engine knob through several patches).
Algorithm-selector change inside 6-op FM has the same effect.

Emulator (x86_64) does not reproduce the crash. The hardware-only
signature is consistent with the Cortex-A8 codegen-trap class
documented in `docs/dev-context.md` and habitat memory
`feedback_runtime_branched_dsp_dispatch` — but in this case the
mi code that was active for previously-working versions has not
changed, so the trigger must be firmware-side.

## Bisect / evidence already collected (habitat-side)

### Binary identity verified
- SD card extraction at `/v0.7/libs/mi/libmi.so` = **MD5
  `f7d90341f0a5c96e705f37b40854eb19`**, size **1,432,413 bytes**.
- Pristine build of habitat commit `a8c8a3c` (mi 1.0.2, the last
  known-working mi release) against current SDK headers
  produces the **same MD5**. Confirmed by:
  ```
  git checkout a8c8a3c -- mods/mi/ eurorack/plaits/
  make mi ARCH=am335x
  md5sum testing/am335x/libmi.so
  ```
- → The libmi.so that's crashing is the same binary that worked
  in the previous session. Habitat made no relevant change.

### SDK header diff scope (between firmware tags)
Diff `v0.7.0-stolmine.9.1.0 .. v0.7.0-stolmine.9.1.0.53`:

| File | Type of change | Affects mi? |
|---|---|---|
| `od/AudioThread.h` | +1 `#include`, +1 static method | No (additive only, no layout change) |
| `od/AudioThread.cpp` | +SequencerTask field in file-local struct, +init code, +accessor | Indirect (changes task scheduler population) |
| `od/sequencer/*` | NEW files | No direct mi reference |
| `od/tasks/SequencerTask.{h,cpp}` | NEW files | No direct mi reference |
| `od/glue/app.cpp.swig` | Sequencer Lua bindings | No |

**No changes to `od/objects/` (Inlet, Outlet, Object, Parameter,
Option) — mi's entire public-API surface.** Verified via:
```
git diff --name-only v0.7.0-stolmine.9.1.0..v0.7.0-stolmine.9.1.0.53 -- od/objects/
```
(empty)

### mi's binary contract with firmware
`arm-none-eabi-objdump -t testing/am335x/libmi.so | grep '*UND*'`
shows mi's external symbol references are all `od::Object`,
`od::Inlet`, `od::Outlet`, `od::Parameter` (constructors,
destructors, `addInput`/`addOutput`/`addParameter`, `buffer()`,
`isConnected`, `hold`/`unhold`). **No reference to
`SequencerTask`, `Sequencer`, or anything Sequencer-related.**
mi was compiled before SequencerTask existed and has no link
to it.

### Frame pool not exhausted
- `AudioThread::framePool.allocate(globalConfig.frameLength, 1024)` — 1024 frames.
- `SequencerTask` owns 24 outlets = 24 frames. ~2.3% consumed.
- Not an exhaustion-class issue.

### Habitat-side things that have been **ruled out**
- mi source code (binary-identical to known-working version)
- mi build flags (`-DTEST` is passed, verified via `make -n`)
- mi SWIG wrapper staleness (regenerated, MD5 stable across builds)
- mi arena overlap (PlaitsVoice arena is private, separate from firmware allocators)
- ABI of base classes (od::Object family — no SDK header changes there)
- mi's polynomial-sine substitution (the libm `sqrtf`/`vsqrt.f32` codegen
  is identical between the working and crashing builds)
- stmlib ARM inline asm (`-DTEST` path is active — verified per
  habitat-side `docs/knowledge-base.md:18-19`)

## Next bisect steps (most informative first)

### Test 1 (RECOMMENDED): fully skip SequencerTask construction

The current `.54-noseq` build still does `new SequencerTask()`
(just skips `addTask`). 24 Outlets get constructed and 24 frames
get consumed from the global pool at firmware init time.
**Construction side-effects haven't been isolated yet.**

Test: in `AudioThread::init()`, comment out BOTH:
```cpp
// local->sequencerTask = new SequencerTask();  // SKIP
// addTask(local->sequencerTask, INT_MAX - 2);   // SKIP
```
Lua bindings break, but that's fine for diagnostic.

- If Plaits/Clouds still crash → SequencerTask is fully innocent,
  the trigger is somewhere else in the 9.0.0→9.1.0.53 firmware diff.
- If they stop crashing → construction-side effects (Outlet
  allocation, frame pool consumption) are the trigger.

### Test 2: audit Rings's model-switch C++ path

Rings works while Plaits + Clouds crash. Find what Rings does
DIFFERENTLY at model-switch. Specifically:
- Does Rings re-init its arena on model change? (Plaits does;
  Clouds likely does)
- If Rings does NOT do arena re-init, that's the structural diff.
  The firmware-side bug is likely something in the arena-reset
  pathway or in code that runs ADJACENT to it (a callback, an
  audio thread event, etc.).

Files to inspect:
- `eurorack/rings/dsp/part.cc` — Rings's Part class, model dispatch
- `mods/mi/RingsVoice.cpp` — wrapper, look for model-switch handling
- Compare to `mods/mi/PlaitsVoice.cpp` + `eurorack/plaits/dsp/voice.cc`

### Test 3: build firmware at `v0.7.0-stolmine.9.0.0` and test

Pre-9.1.0 firmware. If mi works on .9.0.0 but crashes on .9.1.0 →
trigger is in the 9.0.0→9.1.0 diff (chain LED / LocalChooser /
admin mode work), NOT the sequencer work.

Habitat memory `feedback_abi_compatibility` documents this class
of regression — Outlet/Inlet field additions are particularly
breaking for embedded-class-member packages like mi.

### Test 4: inspect per-package error log

`~/.od/front/ER-301/logs/mi.log` should contain crash details if
mi reaches the log-write codepath. Currently only `spreadsheet.log`
exists locally, suggesting either mi never writes a log OR the
crash hard-faults before the logging buffer flushes.

If mi.log exists on the user's emu host but is being created by a
different invocation: check the emu's working dir, not just
`~/.od/front/ER-301/logs/`.

## Other working hypotheses (now lower-priority after bisects)

### Hypothesis A (RULED OUT by `.54-noseq` build): SequencerTask::process side-effects

`SequencerTask` is added to the task scheduler at priority
`INT_MAX - 2`, running every audio frame between `InputTask`
(`INT_MAX - 1`) and channel chains. mi's units execute as part
of channel-chain processing — after SequencerTask runs each frame.

If `SequencerTask::process` has any of:
- buffer-overflow into adjacent task memory
- NaN/denormal output that propagates through downstream chains
- timing-sensitive race vs concurrent UI / engine-switch events
- stack-frame-size growth that breaks downstream task stack
  budgets on Cortex-A8

…it would manifest as **crash in a downstream consumer (mi) at
a moment of extra memory pressure (engine switch path's
`allocator_->Free() + e->Init(allocator_)` re-init dance)**.

Specifically: Plaits' `plaits::Voice::Render` in
`eurorack/plaits/dsp/voice.cc:129-146` does on engine switch:

```cpp
if (engine_index != previous_engine_index_ || reload_user_data_) {
  allocator_->Free();
  e->Init(allocator_);
  // ... LoadUserData, Reset ...
}
```

This is a large, in-place reallocation of the per-engine arena
that happens **within** the audio thread. If SequencerTask's state
machine corrupts memory adjacent to the audio thread's stack, the
crash would surface here — at engine switch — even though the bug
is in SequencerTask.

**Tests to run:**
1. Disable SequencerTask in `AudioThread.cpp::init()` (comment
   out the `addTask(local->sequencerTask, INT_MAX - 2)` line).
   Rebuild firmware. Does mi engine-switch still crash?
2. If yes → bug is elsewhere in 9.1.0.x firmware code.
3. If no → SequencerTask is the trigger; review its
   `process()` for buffer writes (24 outlets, each
   `FRAMELENGTH * sizeof(float)` = 512 bytes), state machine
   transitions, and any unbounded allocation.

### Hypothesis B: AudioThread::init() reordering side-effect

The `addTask(local->sequencerTask, INT_MAX - 2)` adds a task
between two existing tasks. If the underlying TaskScheduler
data structure has a fixed-size table that's now closer to its
capacity, or if reordering tasks affects something in their
init ordering, downstream behavior could change.

**Test**: try registering SequencerTask at priority `INT_MIN + 3`
(after OutputTask but before everything else) instead of
`INT_MAX - 2`. Does the crash move or disappear?

### Hypothesis C: changes outside the diff I can see

Habitat's `er-301/` is on `feature/sequencer` branch. If the
firmware on the device was actually built from a different
revision than I can verify (e.g. a working-tree build with
uncommitted changes that got flashed and then reverted),
the diffs above miss the trigger.

**Test**: `git show v0.7.0-stolmine.9.1.0.53 --stat` and verify
the firmware binary in the user's hands matches the kernel.bin
on the SD. Compare strings extraction
(`strings kernel.bin | grep FIRMWARE`) and confirm.

### Hypothesis D: Cortex-A8 codegen drift in something subtle

If the cross-compiler or any link script changed between firmware
versions, sleeper bugs could surface. The TaskScheduler /
AudioThread changes might pull `od/tasks/Task.h` along a different
inlining path in a way that affects every downstream task's
generated code. Habitat memory `feedback_runtime_branched_dsp_dispatch`
documents the class of failure where small changes in compiled
output crash A8 hardware.

**Test**: build firmware at `v0.7.0-stolmine.9.1.0` exactly
(pre-Sequencer), flash, install the same mi-1.0.3.4-stolmine
package, repeat engine-switch test. Does it crash there?
- If no → confirms regression is in the Sequencer-era commits.
- If yes → regression predates 9.1.0.

## Reproduction recipe for the firmware-side agent

**Hardware setup**:
- Device with firmware `v0.7.0-stolmine.9.1.0.53` flashed
- Rear SD with mi-1.0.3.4-stolmine extracted in `/v0.7/libs/mi/`
- Other habitat packages present (full set per device packages.db,
  but mi is the only one with the issue)

**Repro steps**:
1. Boot device
2. Load a Plaits unit on any chain
3. Cycle the Engine selector through 3-5 engines
4. Crash within a few switches

**Expected**: clean engine switch, audio updates with new engine
**Actual**: crash (UI freeze, audio dropout, or hard hang —
exact symptom per device behavior)

## Pointers to habitat-side artifacts

- `planning/plaits-6op-os-rollback.md` — postmortem from the habitat
  session that confirmed the rollback was clean
- `mods/mi/util/neon_math.h` (habitat) — new file added in the
  session, **unused** by the build, won't affect anything
- `planning/plaits-cpu-reduction.md` — broader Plaits optimization
  roadmap (no firmware impact)
- `feedback_runtime_branched_dsp_dispatch` memory — class of A8
  codegen bug this resembles
- `docs/knowledge-base.md:18-19` (habitat) — prior Plaits engine-
  switch crash from stmlib ARM asm (already mitigated via -DTEST)

## When this gets resolved

Update the resolution status at the top of this doc. If the fix
involves a firmware-side patch, tag a new stolmine.9.1.0.x and
note the diff. Habitat will rebuild mi against the new SDK and
verify.
