# Audio-thread fault quarantine

> **Status**: design / unplanned. Targets a future minor release (v0.8 or
> v1.0 scoped). Goal: turn the dominant class of hard crashes (Cortex-A8
> NEON codegen traps from package DSP) into "unit X faulted, audio
> resumed without it" events.

## Why this is worth building

Every crash we have tracked back to a root cause this year has been one of:

- Cortex-A8 NEON undefined-instruction traps from `-O3 -ffast-math` +
  `-ftree-vectorize` (the mi mode-selector regression; see
  `feedback_mi_swap_crash_not_firmware`)
- Runtime DSP dispatch on the audio thread tripping A8-specific bugs
  (`feedback_runtime_branched_dsp_dispatch`)
- Package trig miscompute on am335x (`feedback_package_trig_lut`)
- Various stmlib inline-asm corners (`vsqrt.f32`, `ssat`, etc.)

All hit the **same final state**: hardware throws an exception inside
some user-installed package's `process()`, TI-RTOS' default handler
takes the whole device down, user power-cycles, posts a stack trace,
we spend a session bisecting.

If the audio thread could **catch the trap, mark the offending unit
dead, and resume audio**, the failure mode becomes "patch with that
unit goes silent and the unit shows a FAULT badge" instead of "device
unusable." Recoverable, debuggable, doesn't require firmware-side
expertise to diagnose.

## Scope

**In:** audio-thread `process()` calls. Specifically the per-unit `process()`
loop inside `OutputTask` / `Chain::process` paths. Each unit gets a
setjmp checkpoint around its call so a fault inside the unit longjmps
back to the checkpoint, the unit gets quarantined, and the audio
thread continues to the next unit / next frame.

**Out:** UI thread crashes, Lua VM errors (already handled), system
task faults (InputTask, OutputTask, SequencerTask -- their faults stay
hard-crashes since recovery doesn't make sense if the audio scheduler
itself dies). Heap corruption that survives the offending unit's
process is also out of scope -- the fault handler can only protect
against synchronous CPU exceptions, not stale-pointer reads that
silently corrupt other state.

**Failure classes covered**:
- Undefined Instruction (A8 NEON codegen traps, illegal asm)
- Data Abort (null deref, unaligned load/store on strict-aligned regs)
- Prefetch Abort (branch to bogus address, vtable corruption)

**Failure classes NOT covered**:
- Heap corruption that doesn't trigger an exception immediately
- Use-after-free where the freed memory hasn't been overwritten yet
- Lua-side errors (already handled by `pcall` chain)
- Hardware lockups (watchdog territory, separate work item)

## Architecture

### 1. Exception handler hooks (TI-RTOS side)

Replace TI-RTOS' default exception handlers for the three relevant
exception classes (UndefInstr, DataAbort, PrefetchAbort) with our
own that:

1. Capture fault context to a fixed-size global buffer (`g_lastFault`):
   PC, LR, CPSR, FPSCR, fault type, fault address (data abort), and
   a snapshot of `g_currentUnit` (set by the audio thread before each
   `process()` call).
2. Reset FPU sticky state (`vmsr fpscr, #0`) so the audio thread can
   continue using NEON.
3. Check `g_activeCheckpoint` -- if non-NULL, `longjmp` back to it
   with a non-zero status. If NULL, fall through to TI-RTOS' default
   panic (a fault outside a checkpoint is a system-level bug).

`od/arch/am335x/hal/exceptions.cpp` is the right home for the C++
side; the assembly stub probably lives next to the existing
`exception_vec.S` (need to find this; not yet read).

Cortex-A8 specifics:
- Exception handlers run in their own mode (UND / ABT) with separate
  banked SP. Need to set up a stack for them at boot.
- LR in the exception context points to the **next** instruction
  after the fault for some classes and the faulting instruction for
  others (architecture-defined). Decode per-class for accurate PC
  reporting.
- NEON registers are NOT saved by TI-RTOS in the default handler.
  We don't need them in the handler itself, but the longjmp target
  expects them in a valid state -- `vmsr fpscr, #0` plus a `vmov.f32`
  zero-fill of D0-D31 in the handler avoids tripping on stuck
  pipeline state immediately after recovery.

### 2. Setjmp checkpoint pattern (audio thread side)

In `OutputTask::process` or wherever the per-unit `process()` loop
lives (need to find -- search od/tasks):

```cpp
// Per-unit, per-frame:
sigjmp_buf checkpoint;
g_currentUnit = unit;
int status = setjmp(checkpoint);
if (status == 0) {
  g_activeCheckpoint = &checkpoint;
  unit->process();   // protected
  g_activeCheckpoint = NULL;
} else {
  // status != 0 means we got longjmp'd here by the exception handler
  unit->quarantined = true;
  logFault(unit, &g_lastFault);
  g_activeCheckpoint = NULL;
}
g_currentUnit = NULL;
```

`g_activeCheckpoint` is a thread-local (or audio-thread-global since
there's one audio thread) `sigjmp_buf*`. `g_currentUnit` is the same
shape -- handler reads it to know who faulted.

**Cost per unit per frame**: setjmp on Cortex-A8 is ~30 cycles. At
typical patch sizes (10-50 units), that's ~300-1500 cycles per frame
overhead, easily absorbed.

**Quarantined units**: skip their `process()` entirely. They render
silence (output buffers stay at last value or zero). Mark visually in
chain view (red border, FAULT badge -- see UI work below).

### 3. Setjmp / longjmp NEON discipline

GCC 4.9.3 (TI SDK toolchain) `setjmp` on Cortex-A8 with hard-float
ABI **does save D8-D15** (callee-saved NEON regs per AAPCS) but NOT
D0-D7 / D16-D31 (caller-saved). That matches AAPCS function-call
convention; the longjmp target's caller expects to have already
spilled caller-saved regs around the setjmp call.

In practice: after longjmp returns, D0-D7 / D16-D31 hold whatever the
exception handler left there. The handler zeros them explicitly (see
above) so downstream NEON ops start from a clean state.

If GCC's setjmp turns out NOT to save D8-D15 reliably (verify with
disassembly), wrap it in a custom version that does. The TI SDK has a
`__sigsetjmp` we may need to override.

### 4. Unit quarantine state

Add to base `Unit` class (`od/objects/Unit.h` -- need to find):

```cpp
bool mQuarantined = false;
int  mFaultCount  = 0;
```

`mQuarantined` is the skip-process gate. `mFaultCount` lets a unit
fault more than once before going permanently dead (e.g. quarantine
after 3 faults in 10 seconds; pure quarantine on first fault is the
v1 simplification).

**ABI consideration**: adding fields to `Unit` shifts the vtable /
sizeof of every package's subclass. Per `feedback_abi_compatibility`,
this is the kind of change that breaks pre-compiled packages. Two
options:

1. Add the fields at the END of `Unit` (after existing members) and
   accept that packages built against the old `Unit` won't have the
   fields read correctly. New packages get the fields; old packages
   get NULL/garbage and miss the quarantine. Not great.
2. Store quarantine state in a side-table keyed by `Unit*` pointer.
   No ABI change. Slight lookup overhead per process call (one hash-map
   read). Probably the right call.

Recommend option 2 unless we're already doing a major ABI version
bump.

### 5. Fault logging

Existing path per `reference_emu_error_logs` memory: `/mnt/crash.log`
for hard crashes, `/tmp/emu.log` for emu runtime. The fault handler
should append to `/mnt/crash.log` (the SD-rear-card path on hardware)
with:

```
[FAULT] 2026-MM-DD HH:MM:SS unit="seq1.cv1 -> Filter.lp"
        type=UndefInstr pc=0x40012a4c lr=0x40012a30 fpscr=0x60000000
        addr=N/A frame=128 sample=64
```

Logging from an exception handler is dangerous (allocates, syscalls).
Realistic approach: queue the fault info into a lock-free ring
buffer, drain it from the UI thread or a dedicated logger task that
formats and writes.

### 6. UI surfacing

Lua side:

- New `app.Unit` method `isQuarantined()` -> bool (SWIG-bound). UI
  reads this each refresh.
- Chain view: quarantined units render with red border + "FAULT"
  text overlay.
- Admin menu entry: "Recent faults" -> list of last N quarantine
  events with timestamp and unit name. Selecting one shows the
  fault context (PC, fault type) for sharing in a bug report.
- Per-unit recovery gesture: long-press on the FAULT badge, or an
  admin-menu "Clear quarantine" entry. Resets `mQuarantined = false`
  and re-tries the unit next frame. If it faults again immediately,
  re-quarantine.

### 7. Optional belt-and-suspenders: stack canary validation

Each unit's process() runs on the audio thread stack. A unit that
corrupts the stack before faulting can leave the longjmp target's
stack in a bad state. Mitigation:

```cpp
volatile uint32_t canary = 0xDEADBEEF;
unit->process();
if (canary != 0xDEADBEEF) {
  // stack corrupted; quarantine more aggressively, skip frame
}
```

Adds ~2 cycles per unit. Worth it for catching the broader class of
"unit corrupted memory but didn't fault" bugs.

## Phasing

### Phase 1: catch + log + continue (target: v0.8 / 1 week)

- Exception handler hooks (UndefInstr only to start; Data/Prefetch
  Abort come in Phase 3)
- Setjmp checkpoint around per-unit process()
- Side-table quarantine state
- Fault ring buffer + drainer task
- Crash.log writing
- Admin-menu "Recent faults" list

Ship as v0.8.0. Most of the value lands here; the package-side bug
class we have been chasing all becomes recoverable.

### Phase 2: UI + recovery gesture (target: v0.8.1 / 0.5 week)

- Chain view FAULT badge
- Long-press / menu recovery gesture
- Sub-display fault-context viewer

Could fold into Phase 1 if it ships fast enough.

### Phase 3: broader exception coverage (target: v0.9 / 1 week)

- DataAbort handler (memory faults; trickier because the faulting
  instruction needs to be skipped or the unit re-attempted at a
  different PC)
- PrefetchAbort handler (branch to bad address; usually fatal but
  worth catching to avoid panic)
- Stack canary validation per unit
- Heap guard pages around critical structures (if TI-RTOS allocator
  supports it; may need to swap allocators or live without)

## Bench / test strategy

**Hard part**: simulating faults reliably for bench coverage.

- **A "fault-on-demand" test unit** (`mods/test/FaultUnit.cpp`):
  Configurable fault type via a Parameter. On `process()`:
  - Type 1: execute `.word 0xe7fddef0` (UDF -- undefined instruction)
  - Type 2: dereference NULL (`*(int*)0 = 1;` -- Data Abort)
  - Type 3: jump to NULL (`((void(*)())0)();` -- Prefetch Abort)
  - Type 0: no-op (control)
- **Bench test in `mods/test/` build**:
  - Load FaultUnit, set type=1, run process() once
  - Assert: audio thread alive (next frame fired), unit quarantined,
    crash.log has new entry with correct unit name
  - Repeat for types 2 and 3 in Phase 3

**Emu coverage** (linux x86_64): map UndefInstr to SIGILL, DataAbort
to SIGSEGV, PrefetchAbort to SIGSEGV with bad PC. Use standard
signal handlers. The setjmp / longjmp logic is portable; only the
exception-vector hooking is am335x-specific. Emu bench can validate
the recovery logic without hardware.

**Hardware coverage**: required for Phase 1 sign-off. Manual test
plan: install FaultUnit, route audio through it, switch to fault
mode, confirm audio resumes within one frame with FAULT badge.

## Risk + open questions

- **TI-RTOS exception vector hooking**: may require linker script
  changes, can be tricky to integrate without breaking the rest of
  the kernel. First implementation pass should validate this end-to-end
  before building UI on top.
- **GCC 4.9.3 setjmp behavior with NEON**: needs disassembly check
  before relying on it. May need a custom setjmp that explicitly
  saves D0-D7 + D16-D31.
- **Quarantine side-table contention**: a hash-map read per
  process() call adds cost. Profile under load (100-unit patch); if
  cost is >1% of CPU budget, switch to embedded bit on Unit (accept
  the ABI break) or another structure.
- **"Soft quarantine" vs "hard crash" philosophy**: a hidden
  quarantine could mask bugs that the user would prefer to see
  immediately. Mitigation: make the FAULT badge VERY visible (red,
  flashing, sub-display alert on first fault) so the user can't miss
  it. Don't silently quarantine without surfacing the event.
- **Cross-fault interaction**: a faulting unit corrupts data that
  another unit reads next frame. Quarantining the faulter doesn't
  protect downstream. Hard to solve generally; document as a known
  limitation.
- **Package compile-flag enforcement** (path 1 in the original
  question): cheaper and more preventive than this work. Recommend
  doing path 1 FIRST as v9.2.x; this work is path 2 as v0.8+.

## Files this work touches (estimated)

- `od/arch/am335x/hal/exceptions.cpp` (new or expanded)
- `od/arch/am335x/hal/exception_vec.S` (or equivalent; need to find)
- `od/tasks/OutputTask.cpp` (checkpoint around unit::process loop)
- `od/objects/Unit.h` + `Unit.cpp` (side-table interface, or new
  embedded field if accepting ABI break)
- `od/extras/FaultRingBuffer.h` (new; lock-free queue)
- `od/AudioThread.cpp` (drainer task or hook)
- `xroot/AdminMode/init.lua` (Recent faults menu)
- `xroot/Chain/ScopeView.lua` (FAULT badge on quarantined units)
- `xroot/SystemInfo/init.lua` or equivalent (recent-faults list)
- `mods/test/FaultUnit.cpp` (new; bench unit)
- `xroot/sandbox/fault_handler_bench.lua` (new)
- `scripts/emu.mk` (signal-handler hookup for emu-side recovery)

## Effort estimate

| Phase | Effort | Output |
|---|---|---|
| 1: catch + log + continue (UndefInstr only) | ~1 week | v0.8.0 |
| 2: UI + recovery gesture | ~0.5 week | v0.8.1 (or fold into 1) |
| 3: broader exception coverage + canaries | ~1 week | v0.9.0 |
| **Total** | **~2.5 weeks** | through v0.9 |

Phase 1 alone delivers 80% of the value because UndefInstr is the
dominant crash class we have observed. Could ship as a standalone
v0.8 milestone; Phases 2-3 polish on top.

## Cross-references

- `feedback_mi_swap_crash_not_firmware` -- the bug class this protects against
- `feedback_runtime_branched_dsp_dispatch` -- same family of A8 codegen traps
- `feedback_package_trig_lut` -- another package-side miscompute that would be quarantined here
- `feedback_neon_aapcs_call_barrier` (habitat) -- the specific NEON pipeline issue, masked by AAPCS spill
- `reference_emu_error_logs` -- where crash.log lives today
- The companion path-1 work (compile-flag enforcement in the package
  build template) is a separate, cheaper, more preventive item.
  Recommend that as a v9.2.x or v9.3 add before tackling this.
