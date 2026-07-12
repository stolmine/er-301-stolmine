# Crash-diag case study: Anamnesis insert data-abort (instrumentation findings)

**Status:** unresolved crash, but a useful stress-test of the crash-diagnostics
facility. This report is written for the FIRMWARE side: what the facility caught,
where it fell short, and the concrete instrumentation upgrades that would have
turned "corruption detected 0.2s after insert" into a named root cause. The
DSP/package-side detail lives in `er-301-habitat: planning/anamnesis-insert-crash.md`.

## The fault (schema-2 capture, fw 0.7.0-stolmine.9.5.2.56)

- `Kind: data-abort`, `Thread: hwi`.
- `pc=0x803d9c0c` -> `ti_sysbios_knl_Event_post` (`Event.c:285`), the line
  `elem->matchingEvents = Event_checkEvents(...)` where `elem = Queue_head(pendQ)`.
- `dfsr=0x5` (translation fault), `dfar=0x00000062` (near-null deref at field
  offset 0x62). NOT `dfsr=0x1` (alignment / NEON `:64`).
- `r8=0x49002070` = the AM335x EDMA register block -> this is the **audio EDMA
  completion ISR** calling `Event_post` to wake the audio task.
- Flight recorder: `14.939s insert Anamnesis`; fault at `15.160s` (~0.22s later).

Read: a stray write during Anamnesis insert clobbered the audio `Event`'s
pend-queue pointer chain to a near-null value; the next audio interrupt walked the
corrupted queue and trapped. **The fault fires where corruption is DETECTED, not
where it was CAUSED.**

## What the facility got right (keep all of this)

The capture pipeline performed well and was decisive in narrowing the problem:

- **pc symbolization** to `Event_post` (via `tools/symbolize_crash.py` + the matching
  `app.elf`) - immediately named the victim.
- **`dfsr`/`dfar`** - classified it as a corrupted-pointer deref (translation
  fault at a near-null address), NOT an alignment/NEON trap. This single fact
  redirected the whole investigation away from the usual am335x NEON `:64` suspect.
- **Module map** - listed `libanamnesis.so` and bounded `pc` to the kernel, telling
  us WHICH package to look at while confirming the fault surfaced in kernel code.
- **`r8` = EDMA register block** - identified the ISR context (audio path) without
  guesswork.
- **Flight recorder** `insert Anamnesis` 0.2s prior - the single most useful line;
  it tied the corruption to the insert path.
- **Warm-reboot-surviving panic buffer -> next-boot flush to `front/crash.log` ->
  offline symbolize** - the end-to-end mechanism worked as designed.

Off-hardware, this let us RULE OUT the easy causes: not a logic index-OOB (ASan on
the same package in the emu + a full write-path audit came back clean), not a NEON
alignment trap (`dfsr=0x5`), not a stale-SWIG sizeof mismatch (the package is
single-TU). The leading remaining hypothesis is an **am335x task-stack overflow**
(invisible to x86 ASan): the unit's viz draw path runs ~2.4 KB of stack-local
arrays on a small SYS/BIOS task stack.

## Where the instrumentation fell short (prioritized asks)

Because this is a delayed-detection corruption, the current report cannot point at
the corruptor. The upgrades below would close that gap - and they generalize to
any heap/stack corruption case, not just this one.

### 1. Per-task stack high-water + overflow/canary flag in the report  [HIGHEST VALUE]
Our leading hypothesis is a stack overflow, and the facility currently cannot
confirm or deny it. SYS/BIOS already supports stack checking (Task stack canary /
`Task_stat.used`, `Hwi.checkStackFlag`). Capture, per task, into the crash report:
stack base, size, **high-water used**, and a **canary-intact** boolean; plus the
Hwi/system-stack high-water. A blown display/UI task stack would be obvious at a
glance. Stack overflow is a top-tier embedded corruption source, so this pays off
far beyond this bug.

### 2. Guard / canary the long-lived critical kernel objects
The victim is the audio `Event` + its pend queue - a small, boot-time, long-lived
allocation. Put a guard word (or an MPU guard region, if the A8 MMU config allows)
immediately around that `Event`, and check it cheaply at each `Event_post` (or from
a low-rate watchdog). Catching the guard breach NEAR the write - ideally recording
the writing `pc` - converts delayed detection into direct attribution. Even a
periodic integrity check of `event->pendQ` that logs "pendQ corrupted, first seen
at T" would shrink the corruption window enormously.

### 3. Fix the partial register capture (sp / psr)  [already tracked]
The A8 trap frame gave `sp==pc` and a bogus `psr` (the SYS/BIOS-6.46 ExcContext
artifact tracked as `crashdiag-fix-partial-register-capture`). With no valid `sp`
there is no stack unwind, so we get the fault site but not the call chain - and no
frame to hang #2's corruptor-capture on. This remains the highest-leverage register
fix.

### 4. Resolve (or explicitly flag) `lr`
`lr=0x81a5aaa4` symbolized to `lr in ?` - not in the kernel range or any listed
module. Either the module map is missing a range or `lr` is garbage from the same
partial-frame issue (#3). Symbolizing `lr` against the module map, or flagging it
"unresolved (outside all known ranges)", is a cheap clarity win.

### 5. Flush the C-side log ring into the report
`Recent Log: (not captured C-side; see flight recorder above)`. Only the flight
recorder survived. Dumping the last N lines of the existing C-side log ring into
the panic buffer would add human-readable context around the insert.

### 6. Finer flight-recorder markers around unit insert
One `insert Anamnesis` marker yields a 0.2s window. A few more near-free markers -
unit `construct-complete`, `first-process-block`, and `large-heap-alloc(size, ptr)`
- would narrow that window and, combined with #1/#2, pin the corruption to a phase.

## Bottom line

The facility caught, symbolized, and contextualized a real delayed-corruption
data-abort well enough to eliminate the obvious causes off-hardware. Its one
structural gap is that it reports the **detection** site, not the **corruption**
site. Adding stack high-water/canary reporting (#1) and critical-object guards (#2)
would turn "corruption detected in `Event_post`, 0.2s after insert Anamnesis" into
"task Y overflowed its stack" or "object Z clobbered at pc W" - i.e. the difference
between a hypothesis and a fix. Both are broadly reusable, not specific to this bug.

---
*Provenance: investigated 2026-07-12. Capture: fw 9.5.2.56, `enableCrashDiagnostics`
armed. Off-hardware analysis (ASan-in-emu + source audit) and the DSP-side write-path
audit are in `er-301-habitat: planning/anamnesis-insert-crash.md`. See also
`docs/CRASH_REPORT_FORMAT.md`, `planning/crash-diagnostics-plan.md`.*
