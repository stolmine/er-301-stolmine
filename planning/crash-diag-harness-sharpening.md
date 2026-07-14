# Crash-diagnostics harness sharpening — implementation plan

**Goal:** close the two structural gaps the Anamnesis insert data-abort exposed
(`docs/HABITAT_ANAMNESIS_INSERT_ABORT.md`), WITHOUT fixing the crash. We are
sharpening the tool, not the target.

The two gaps:
1. **Attribution.** The facility reports the DETECTION site (the fault in
   `Event_post`, 0.2s after insert), not the CORRUPTION site (whoever wrote the
   bad value). Close it by moving detection closer to the corruption in SPACE
   (stack canaries, object guards) and TIME (finer markers, integrity polls).
2. **Coverage is audio-shaped.** Heartbeat, hang monitor, and the ISR context we
   decode all key off the audio path. But this crash is a UI action (insert) whose
   leading suspect is a stack overflow in the viz DRAW path, which runs on the MAIN
   (UI) task. We are blind to the UI/display thread's stack, liveness, and activity.

## CURRENT STATE (2026-07-14) -- resume here

The base facility (`infra-crash-diagnostics-debug-mode`) is DONE + bench-validated:
traps, audio hangs (+ live spin-pc), per-task stacks, the arm toggle. On top of it,
the sharpening items below. Bench firmware ladder (each is a clean single-version
build; Anamnesis pkg 0.2.0.83 is the FROZEN fixture): `.53` spin-pc -> `.56` UI arm
toggle -> `.58` P0 stacks (abort-safe) -> `.60` P2 guard -> `.62` P3 heap -> **`.63`
P1a UI-hang (the current omnibus: stacks + guard + heap + opt-in UI-hang)**.

- **P0 `crashdiag-stack-highwater`** -- DONE, bench-validated (`.58`). Disproved the
  stack-overflow hypothesis; surfaced the corrupted Task_Object. Abort-safety lesson:
  DDR-range-check every read (the `.57` build HUNG walking corrupted structures).
- **P2 `crashdiag-object-guard-event`** -- tier 1 DONE, emu-verified, BENCH-PENDING
  (`.60`+). pendQ-invariant guard catches the corruption at the first Event_post.
  Tier 2 (the writing pc via an A8 watchpoint) NOT shipped -- DBGEN-gated, needs a
  bench probe; deprioritized (superseded by P3).
- **P3 `crashdiag-heap-stats`** -- DONE, emu-verified, BENCH-PENDING (`.62`+). Names
  the Anamnesis footprint root cause directly (arena vs the 20 MB kernel_heap
  ceiling + last-alloc-fail). Supersedes P2 tier 2.
- **P1a `crashdiag-ui-heartbeat`** -- DONE, emu-verified, BENCH-PENDING (`.63`).
  OPTION C: UI-hang detection is a SEPARATE opt-in (`enableUiHangDetection`), ~3s
  threshold + a Busy.status pump, so it never reboots on a legit long op.
- **P1b `crashdiag-ui-flightrecorder-seams`** -- PLANNED, not started (§P1b).
- **P1c `crashdiag-insert-lifecycle-markers`** -- PLANNED, not started (§P1c).
- **C1 `crashdiag-resolve-lr`** -- PLANNED, not started (cheap; §C1).
- **C2 `crashdiag-flush-log-ring`** -- PLANNED, not started (cheap; §C2).
- Open refinements (own items): `crashdiag-fix-partial-register-capture` (the
  `sp==pc`/`psr` A8 trap-frame gap -- gates any stack UNWIND) and
  `crashdiag-fix-flush-error-handling` (M4, needs a full/failing-card bench).

**Next-step guidance:** (a) bench `.63` on the frozen Anamnesis insert to validate
P2/P3/P1a capture at once (expect the `--- Heap ---` NEAR-CEILING banner + the pendQ
guard breach); (b) then the cheap C1/C2 (both touch PanicBuffer.cpp + the symbolizer,
so do them SERIALLY); (c) P1b/P1c add UI activity context to the flight recorder.
`crashdiag-fix-partial-register-capture` is the highest-leverage refinement (unlocks
call-chain unwind for every report). All CAPTURE is am335x-hardware-only; the
format/viewer/symbolizer halves are emu-testable via `injectSynthetic`.

## Standing test fixture: Anamnesis insert (frozen)

Anamnesis (`er-301-habitat: mods/anamnesis`, pkg 0.2.0.83) will be held UNCHANGED
as the live regression target. Its insert reliably corrupts the audio `Event` and
traps in `Event_post` on am335x hardware (ASan-clean in the emu, so it is a
hardware-manifest corruption — most likely a MAIN/DISPLAY task-stack overflow from
the ~2.4 KB stack-local viz arrays). Every item below states how it should behave
when the harness is pointed at this exact insert. When P0 lands, we expect it to
name the blown task outright.

## Report-format + PanicRecord evolution (shared contract)

All on-device additions extend the schema-2 block in `docs/CRASH_REPORT_FORMAT.md`
and the C `PanicRecord` in `arch/am335x/hal/crash/PanicBuffer.cpp`. Rules that hold
for every item:
- Bump `PANIC_VERSION` on any `PanicRecord` layout change; keep the
  `static_assert(sizeof(PanicRecord) <= 0x4000)` (currently ~0x2338, ample room).
- Keep the C flush, the Lua/emu injector (`xroot/CrashReport.lua`), and
  `tools/symbolize_crash.py` in agreement on any new text section; add an emu
  harness assertion for each new section via `injectSynthetic`.
- Zero-cost-when-off: every new capture keys off the existing armed flag
  (`enableCrashDiagnostics` -> `flightRecorderArm` -> the shared choke point), and
  every new heartbeat/marker is a single predicted branch when disarmed.

---

## P0 — Per-task + ISR stack high-water and canary in the report  [HIGHEST VALUE]

**Why first:** directly tests the standing hypothesis (which task overflowed) AND
is the entry point for UI coverage AND generalizes to every future stack-overflow
corruption. Likely closes the Anamnesis case outright.

**Feasibility (verified in bios 6.46):**
- `Task_Stat` already carries `used` (`ti/sysbios/knl/Task.h:113`) — the
  high-water, computable because SYS/BIOS pre-fills task stacks with `0xBE`.
- `Task_Object_first()` / `Task_Object_next()` (`Task.h:1172-1173`) enumerate every
  task, so we can report ALL of them, not just audio.
- The `0xBE` canary + `Task_SupportProxy_checkStack(stack, size)` /
  `Task_checkStacks` already exist (`Task.c:385-417`) for a canary-intact check.
- `Hwi_getStackInfo(StackInfo*, computeStackDepth=TRUE)` gives the ISR/system-stack
  base/size/high-water.
- **Prerequisite:** confirm `Task.initStackFlag` is TRUE (stacks pre-filled with
  `0xBE`) in `arch/am335x/sysbios/common.cfg`. It currently sets
  `Task.checkStackFlag=false` / `Hwi2.checkStackFlag=false` (no continuous
  per-switch check — fine, we compute at capture time), but high-water NEEDS the
  pre-fill. If `initStackFlag` is not already default-true, set it (cost: one stack
  fill at task create, no steady-state cost).

**Design:**
- New `PanicRecord` section: `PanicStackEntry stacks[PANIC_MAX_TASKS]` (propose 16)
  each `{ char name[16]; uint32_t base, size, used; uint8_t canaryOk; }` + a
  `uint32_t stackCount` and a single `uint8_t anyStackBlown` summary. Plus one
  `PanicStackEntry` for the ISR/system stack.
- Capture routine `panicEnumerateStacks(...)`: walk `Task_Object_first/next`; for
  each, read `stat.stack/stackSize/used` and check the canary word; name via
  `Task_getEnv` (same as the existing thread-name path). Then `Hwi_getStackInfo`
  for the ISR stack. Shared by BOTH the trap hook and the hang capture.
- **Abort-context safety:** the trap hook runs in a fault context, so do NOT rely
  on `Task_stat`'s internal `Task_disable/restore` if it is unsafe there. Prefer a
  self-contained walk: read `tsk->stack`/`stackSize` (bounded reads) and compute
  high-water ourselves by scanning from the stack base for the first non-`0xBE`
  word (pure memory reads, allocation-free, bounded by stackSize). This is the
  safest form and avoids any scheduler lock. Validate on the bench that the walk is
  fault-free from the abort context (the hang path runs in the gentler Swi context
  and can use `Task_stat` directly if preferred).
- Flush: a `--- Stacks ---` section, one line per task:
  ` <name-16>  base=<hex> size=<n> used=<n> (<pct>%) canary=<ok|BLOWN>` and an
  ` isr  base=.. size=.. used=.. (<pct>%)` line; if `anyStackBlown` or any
  `used > 90%`, also emit a top-of-report ` *** STACK <name> BLOWN/NEAR-FULL ***`
  banner so it is unmissable.
- Symbolizer: parse `--- Stacks ---` and, when present, lead its output with the
  blown/near-full task before the register/backtrace dump.

**Zero-cost/arming:** enumeration only runs at capture time (already gated). The
`0xBE` pre-fill is a create-time cost only.

**Verify:**
- Emu: `injectSynthetic` a canned `--- Stacks ---` block (one task `BLOWN`); assert
  the viewer + symbolizer surface the banner. Add `tests/emu/47-crash-diag-stacks`.
- Hardware (Anamnesis): insert Anamnesis with diagnostics armed; the resulting
  `data-abort` (or hang) report should now carry `--- Stacks ---`. EXPECTED result
  per the hypothesis: the MAIN or DISPLAY task shows `used` at/over `size` and/or
  `canary=BLOWN`. That is the root cause named. If NO stack is blown, the
  hypothesis is wrong and P2 (object guard) becomes the path.

---

## P1 — Instrument the UI / display thread

The corruptor is very likely a UI-thread activity (viz draw on insert). Three
pieces; P1a is the highest value.

### P1a — UI/main-thread heartbeat + hang-monitor coverage

**Why:** today the hang monitor watches ONLY audio; a UI-thread spin (a hanging
constructor, an infinite draw) produces NO report at all. Extend the existing
Swi-context Clock monitor (`arch/am335x/hal/crash/HangWatchdog.cpp`) with a second
heartbeat for the main task.

**Design — the idle-block nuance:** the main loop (`xroot/Application.lua:554`
`loop()`) legitimately BLOCKS in `waitForEvent()` (`app.Events_wait`) when idle, so
"loop iterations stalled" is NOT a hang by itself. Use a busy-gated heartbeat that
mirrors the audio `g_audioRunning` pattern:
- New C globals `g_uiFrames` (counter) + `g_uiBusy` (flag), exposed to Lua via a
  glue call (e.g. `app.uiHeartbeat(busy)` in `od/glue/CrashDiag.cpp`, no-op when
  disarmed).
- In `loop()`: set busy=true + bump `g_uiFrames` at `startEventTimer()` (processing
  begins — note this seam already exists), and set busy=false right before
  `waitForEvent()` (about to block idle). So `g_uiBusy` is true exactly while the
  main task is executing a handler / draw / trigger.
- Monitor tick: if `g_uiBusy` AND `g_uiFrames` has not advanced for K ticks
  (~250 ms — no single gesture/draw should take that long) -> declare a UI hang and
  `PanicBuffer_captureHang()` with the MAIN task as the target (reuse the live-SP
  path: `Task_self()` in the Swi will be the main task if it is spinning).
- `startEventTimer` may already implement a soft event-duration watchdog — inspect
  it; the heartbeat can piggyback on the same seam rather than adding a parallel one.

**Verify:** a `BUILDOPT_CRASH_TEST` `'U'` trigger that livelocks inside a Lua
gesture handler (analog of the audio `'h'`), asserting the monitor fires with
Thread=main and the stack window resolves into the UI dispatch path. Emu can test
the format via a synthetic Thread=ui hang record; the CAPTURE is hardware-only.

### P1b — On-device UI-seam flight-recorder markers

**Why:** the flight recorder gave one useful line (`insert Anamnesis`) but no UI
trail. The emu already models the seams (`xroot/emu/Trace.lua`, EMULATION-only:
`Application.setVisibleContext`, `Window:show/hide`, `Context:add/remove`). Wire the
SAME seams to the on-device `FlightRecorder.record()` (which is a no-op branch when
disarmed, so it is always safe to call).

**Design:** add `require('FlightRecorder').record(...)` at the centralized choke
points (already identified by the emu trace work):
- `Application.setVisibleContext` -> `record("ctx " .. name)`
- `Window:show/hide` -> `record("win+ "/"win- " .. name)`
- `Context:add/remove` -> `record("push/pop " .. name)`
Keep the set small (the bus is chatty; context/window/stack only). Result: the FR
reads `ctx admin -> insert Anamnesis -> ctx <unit> -> ...` instead of a lone marker.
Guarded by the armed flag; zero cost off. Subsumes the "finer markers" ask.

### P1c — Unit-lifecycle markers (construct-complete / first-process)

**Why:** narrows the 0.2s insert window to a phase. `xroot/Chain/Base.lua:loadUnit`
already records `insert` + `insert-ok`. Add:
- `record("construct-complete " .. id)` right after `UnitFactory.instantiate`
  returns (still main thread) — separates a constructor fault from a first-process
  fault.
- `first-process` (audio thread, LOWER priority / optional): record the first time
  the audio task calls a newly inserted unit's `process()`. Needs an audio-side FR
  record (the FR ring is C-side and audio-safe), so it is cheap but requires a hook
  in the audio unit-dispatch path. Defer if the audio-side seam is awkward.
- Optional `draw-enter` for heavy graphics: a marker when a flagged graphic's
  `draw()` begins. Fine-grained; defer unless P0/P1a do not localize it.

---

## P2 — Guard / canary the long-lived critical kernel objects

**Why:** the deepest attribution win — catch the corruption NEAR the write. Only
pursue if P0 shows NO blown stack (i.e. the corruptor is a stray heap write, not an
overflow).

**Design:** place a guard word (magic, e.g. `0xC0DEFEED`) immediately before and
after the audio `Event` allocation (`local.hEvents` in `arch/am335x/hal/audio.c`,
created at `Audio_init`). Check both guards cheaply at each `Event_post` in the ISR
(`audio.c:358/372`) and/or from a low-rate watchdog. On breach: record
`record("EVENT GUARD BREACHED")` + capture the current `pc`/`lr` (the writer is long
gone in the deferred case, but the FIRST-SEEN timestamp still shrinks the window;
combined with an MMU guard region it could trap the writer directly). A stretch
variant: an MPU/MMU guard page around the object so the offending WRITE itself
traps with the corruptor's `pc` — feasible only if the A8 MMU config has a spare
region; investigate `arch/am335x` MMU setup before committing.

**Verify:** hard to synthesize; validate against Anamnesis (if it is a heap write,
the guard fires; if it is a stack overflow, P0 already caught it and P2 is moot).

---

## Cleanups (cheap clarity wins)

### C1 — Resolve / flag `lr`
`lr=0x81a5aaa4` symbolized to `lr in ?`. Either the module map lacks a range or `lr`
is garbage from the partial-frame issue. `panicResolve` already runs on `lr`; make
the "outside all ranges" case print `lr = ? (outside all known module ranges)` so
the reader knows it is unresolved-not-forgotten. Cross-check the module map is not
missing a package range. Trivial.

### C2 — Flush the C-side log ring into the report
`Recent Log: (not captured C-side)`. The C-side log ring (`arch/am335x/hal/log.cpp`
LogThread queue) is not drained into the panic buffer. Copy the last N lines into a
new `PanicRecord` field and emit them under the existing `--- Recent Log ---`
header. Care: the log ring is a `LockFreeQueue`; read it allocation-free and
bounded from the capture context. Adds human-readable context around the insert.

## Foundational dependency (already tracked, not re-filed)

`crashdiag-fix-partial-register-capture` — with `sp==pc` there is no valid stack
pointer, so no stack UNWIND (call chain), and nothing for P2's corruptor-capture to
hang on. It gates the quality of P0's window and any unwind. Highest-leverage
register fix; keep it on the list.

## Build order

1. **P0** (stack high-water + canary) — standalone, highest value, likely closes
   the standing case. Confirm `Task.initStackFlag`, add the section + capture +
   flush + symbolizer + emu test, bench against Anamnesis.
2. **P1a** (UI heartbeat) — extends the hang monitor; independent of P0.
3. **P1b** (UI FR seams) + **P1c** (lifecycle markers) — Lua-only, cheap, parallel.
4. **C1** (lr) + **C2** (log ring) — cheap, parallel, any time.
5. **P2** (object guard) — only if P0 shows no blown stack.

Each firmware item is am335x-hardware-only for CAPTURE (verify format/viewer/
symbolizer in the emu via `injectSynthetic`; verify capture on the bench against
the frozen Anamnesis insert). Both arches must build clean; the version-staleness
rule applies (clean build + `strings app.elf` single-version before any bench).

## Success criterion

Re-run the frozen Anamnesis insert with the sharpened harness and get a report that
NAMES the corruptor — "task <X> blew its stack (used > size, canary BLOWN)" (P0), or
"EVENT guard breached" (P2) — instead of "corruption detected in Event_post 0.2s
after insert." That is the difference between a hypothesis and a fix, and every
mechanism here is reusable for the next corruption, not specific to Anamnesis.

---

## P2 IMPLEMENTED 2026-07-12 (`crashdiag-object-guard-event`) — Tier 1 shipped

P0's `--- Stacks ---` section DISPROVED the stack-overflow hypothesis on hardware
(every task stack healthy, canary=ok) and surfaced the real cause: a **wild WRITE**
into the runtime task-object/heap region near `~0x80538xxx` that clobbers BOTH a
Task_Object AND the audio `Event`'s pend queue; the next audio EDMA interrupt walks
the wrecked pendQ and traps in `Event_post`. So P2 (object guard) is the path, and
it is now built.

### Tier 1 (shipped): audio-Event pend-queue integrity guard

Not a literal "guard word bracketing the heap-allocated Event" — that is
**counterproductive here**: the wild write targets a fixed-ish absolute address
(uninitialized/dangling/derived pointer, per the habitat analysis), so relocating
the Event into a guarded static struct would move the victim OUT of the write's
path and suppress the very signal we want (and change the frozen repro's layout).
Instead we keep the Event exactly where `Event_create` puts it and check the
**pend-queue words that get clobbered** (the deliverable's explicit "and/or the
specific pend-queue words" option), which is layout-preserving and directly
targets the corruption.

- The pendQ is a SYS/BIOS `Queue_Object` == a doubly-linked-list sentinel
  `Queue_Elem { next, prev }`. In every legitimate state the invariant holds:
  `next`/`prev` mapped + 4-aligned, and `next->prev == header && prev->next ==
  header`. The Anamnesis clobber (near-null `next`) breaks it.
- `Audio_init` publishes the Event via `PanicBuffer_setAudioEvent()`; the audio
  EDMA/error ISRs call `PanicBuffer_checkAudioEventGuard()` (gated on `g_hangArmed`
  = one predicted branch when off) BEFORE `Event_post`; the Swi hang tick calls it
  too as a low-rate backstop. On breach it seals a `PANIC_FAULT_GUARD` record
  (kind `event-guard-breach`) with FIRST-SEEN wallclock + the corrupted next/prev
  + reason bitmask + the per-task stacks (which also carry the clobbered
  Task_Object), then warm-reboots + flushes exactly like the trap path. Every
  dereference is DDR-range-checked (reuses P0's `panicAddrInDdr`), so a corrupted
  link never nested-faults the capture.
- The check runs in the EDMA Hwi, and the audio task only mutates pendQ under
  `Hwi_disable`, so the check always observes a settled queue: no false positives.

This shrinks the corruption window from ~0.2s (the downstream `Event_post` trap) to
one audio frame and CONFIRMS the pendQ as the victim, without needing the exact
corruptor pc.

New report contract (C flush / Lua injector / `symbolize_crash.py` all agree):
```
Kind: event-guard-breach
 *** EVENT GUARD BREACH (audio pendQ corrupted) ***
--- Event Guard ---
 pendQ=<hex> next=<hex> prev=<hex> reason=<hex>
 reason: next-badptr prev-badptr next-link prev-link   (only the failed rules)
```
`reason` bits: `0x1` next-badptr, `0x2` prev-badptr, `0x4` next-link, `0x8`
prev-link. `PANIC_VERSION` 6 -> 7; `static_assert(sizeof(PanicRecord) <= 0x4000)`
still holds (record ~0x256c). Emu-tested via
`injectSynthetic("event-guard-breach")` + `tests/emu/48-crash-diag-event-guard`
and the symbolizer selftest.

### Tier 2 (NOT shipped) — A8 self-hosted data watchpoint: feasibility VERDICT

Goal: trap AT the store and record the corruptor pc. Evaluated the Cortex-A8
self-hosted (monitor-mode) data watchpoint and the MMU guard page.

**A8 monitor-mode watchpoint — PLAUSIBLE IN PRINCIPLE, but NOT shippable blind, so
NOT shipped.** The mechanism would be: clear the OS lock (`DBGOSLAR`), enable
monitor debug mode (`DBGDSCR.MDBGen`, CP14 c0,c1,c0,2), program `DBGWVR0`/`DBGWCR0`
(CP14 c0,c0/c1,c7) to watch a word on WRITE with privileged+user access. A
watchpoint debug event in monitor mode is taken as a **Data Abort** (`DFSR.FS =
0b00010`, debug event; `DBGDSCR.MOE = 0b0010`, watchpoint), which routes to the
SAME SYS/BIOS Data Abort vector that already calls `stolCrashExcHook` — so the
capture path is reused and `LR_abt` gives the corruptor pc (imprecise by a few
instructions on A8, but enough to name the function via `symbolize_crash.py`).

Why it is not shipped:
1. **DBGEN is the hard gate and is NOT firmware-verifiable in the emu or from
   source.** `MDBGen` is RAZ/WI unless the external `DBGEN` signal is asserted. On
   a GP AM3358 (JTAG works out of the box) `DBGEN` is very likely high, but "very
   likely" is not "verified," and if it is low the watchpoint is a SILENT no-op.
   Per "do not ship a half-working watchpoint," this must be proven on the bench
   first (probe below), not assumed.
2. **No clean watch target without a bench repro.** The word the wild write hits
   (the pendQ `next`, or a Task_Object `stack`/`stackSize`) is at a
   **runtime-determined** address. The pendQ has heavy legit `Event_post`/`pend`
   traffic, so a watchpoint there fires every audio frame and needs per-frame
   disable/step-over/re-enable filtering by writing pc (kernel vs package) — fragile
   and hot. The clean no-legit-traffic target (a Task_Object `stack`/`stackSize`,
   written only at task-create) needs the specific clobbered object's address,
   which only a bench repro pins down. So even with DBGEN confirmed, the watch
   address must be sourced from a bench capture first.

**MMU guard page — NOT VIABLE HERE.** The current MMU config maps DDR in 1 MB
SECTIONs, and `~0x80538xxx` is dense live memory (task objects + stacks + the
Event). A read-only guard SECTION (or even a 4 KB page) covers many legitimately
written objects and would trap constantly. Isolating the Event onto its own guard
page requires relocating it, which (as in Tier 1) moves it out of the write's path
and defeats the purpose. Documented as not-viable in favor of the watchpoint.

**Bench probe to unblock Tier 2 (run before ever enabling a watchpoint):** in a
`BUILDOPT_CRASH_TEST`-style build, from a privileged context: clear `DBGOSLAR`,
set `DBGDSCR.MDBGen`, **read `DBGDSCR` back** and confirm `MDBGen` stuck (if not ->
DBGEN is low -> Tier 2 is dead on this board, stop). Then set `DBGWVR0` to the
address of a local `volatile uint32_t`, `DBGWCR0` to watch-on-write+enabled, store
to that local, and confirm control lands in `stolCrashExcHook` with `DFSR.FS ==
0b00010`. If it fires, Tier 2 is feasible: pin the clobbered Task_Object address
from a Tier-1 `event-guard-breach` / trap capture, watch its `stackSize` field, and
the corruptor pc appears in `libanamnesis.so`. This probe is documented, not
compiled into any normal build.

### On-hardware BENCH procedure for the frozen Anamnesis insert (Tier 1)

1. Flash `0.7.0-stolmine.9.5.2.60` (this build); confirm single version via
   `strings app.elf`.
2. Admin > System Settings > "Enable crash diagnostics?" = on (arms the flight
   recorder + hang monitor + the audio-Event guard on the shared choke point).
3. Insert the frozen Anamnesis (`er-301-habitat` pkg 0.2.0.83), UNCHANGED.
4. The device should warm-reboot and, on next boot, show "A crash was captured."
5. Admin > Crash Reports (or `front/crash.log`): SUCCESS =
   `Kind: event-guard-breach` with the `*** EVENT GUARD BREACH ***` banner, an
   `--- Event Guard ---` section whose `next=` is the near-null clobbered value
   (e.g. `00000062`) with `reason` including `next-badptr`, a FIRST-SEEN `Time
   Since Boot` EARLIER than the old ~15.16s `Event_post` trap, and a `--- Stacks
   ---` section that still shows the clobbered blank-name Task_Object. This proves
   detection moved from the downstream `Event_post` trap to the pendQ write's first
   post. (If instead the old `data-abort in Event_post` still appears, the guard
   check did not run before the corrupting post reached `Event_post` — investigate
   ISR ordering; the guard is called at the top of every EDMA/error ISR so this
   should not happen.)

---

## P3 — Heap pressure + allocation-failure reporting  [added 2026-07-13]

**Why:** the Anamnesis root cause turned out to be **heap exhaustion / footprint**
(habitat 2026-07-13: it is designed for more RAM than the am335x has; it grows the
heap until the allocator hands out overlapping/garbage memory, and its own writes
then land on the live audio `Event` + a Task_Object at `~0x80538xxx`). The harness
reports STACK usage (P0) but NOT heap usage, so it could not see the actual failure
class at a glance. P3 is the heap analog of P0: put heap pressure in every crash
report, and catch a failing allocation at the source. It generalizes to any
over-footprint unit and would have printed "heap at the ceiling" outright.

**The allocator (verified):** `arch/am335x/hal/heap.c` `Heap_memalign/malloc/calloc
/realloc/free` wrap **newlib `malloc`** over the linker `__unused_memory_start__..
__unused_memory_end__` region (NOT the SYS/BIOS default heap; `Memory_getStats`
measures a different heap and walks a free list). DSP unit buffers
(`Heap_memalign`, `BufferPool`, `AlignmentAllocator`) all route through here.

**Abort-safety (the P0 lesson, again):** do NOT walk the heap free list or call
`mallinfo`/`Memory_getStats` from the fault/Swi capture context -- the list is
exactly what a heap-exhaustion bug corrupts, and those calls take the malloc lock.
Instead track everything in the `Heap_*` wrappers into plain globals and have the
capture just READ them (like the P0 stacks / the heartbeat pattern).

### Tier 1 (MVP): heap pressure in every report
Instrument the `Heap_*` wrappers to maintain, as plain globals (cheap, always-safe
to read at capture):
- `g_heapCeiling` = `Heap_getUnusedMemorySize()` (static arena size).
- `g_heapArenaHighWater` = max over allocs of `sbrk(0) - __unused_memory_start__`
  (how far the newlib arena has grown toward the ceiling; a monotonic proxy for
  peak footprint -- newlib rarely returns the break, so this is the exhaustion
  signal). Update on each `Heap_memalign/malloc/calloc/realloc`.
- `g_heapAllocCount` (running alloc count, cheap leak/activity signal).
Add `uint32_t heapCeiling/heapArenaHighWater/heapAllocCount` to `PanicRecord`
(bump `PANIC_VERSION`), fill from the globals in BOTH the trap hook and the hang
capture, flush a `--- Heap ---` section:
` ceiling=<n> arena-highwater=<n> (<pct>%) allocs=<n>` plus a top-of-report
` *** HEAP NEAR-CEILING (<pct>%) ***` banner when the arena high-water is within a
threshold (propose >=90%) of the ceiling. Symbolizer leads with it when near-full.
Gate on the armed flag for the update cost (a couple of instructions per alloc when
off is acceptable, but prefer gating to keep off-parity). Emu: `injectSynthetic
("heap")` + a `tests/emu/49` format test.

### Tier 2 (high value): allocation-failure hook
In the `Heap_*` wrappers, when the underlying `malloc/memalign/calloc/realloc`
returns `NULL` (allocation failed = the allocator is out of room), record it: the
requested `size`, the caller `pc` (`__builtin_return_address(0)`), and the current
arena high-water, into globals; if diagnostics are armed, SEAL a `PANIC_FAULT_ALLOC
_FAIL` ("alloc-fail") record (reusing the trap/hang capture spine from a normal task
context, like the hang path) and warm-reboot so the failing allocation is named
directly (`size` + caller in libanamnesis) rather than surfacing as a later wild
write. NOTE: if the exhaustion manifests as OVERLAPPING allocations (a non-NULL bad
pointer) rather than a clean NULL, Tier 2 will not fire but Tier 1's near-ceiling
banner still shows the pressure -- so Tier 1 is the guaranteed signal, Tier 2 the
precise one.

### Verify
- Emu: synthetic `--- Heap ---` block + banner render + symbolizer lead (tests/emu/49).
- Hardware (frozen Anamnesis): the insert's crash/guard report should now carry a
  `--- Heap ---` section with `arena-highwater` at/near the `ceiling` and a
  ` *** HEAP NEAR-CEILING ***` banner -- naming the footprint root cause directly.
  If Tier 2 fires, an `alloc-fail` report with the requested size + a caller pc in
  `libanamnesis.so`.

### Priority note
Given the confirmed footprint root cause, P3 supersedes P2 Tier 2 (the A8 watchpoint
for the exact wild-write pc): the watchpoint chases a symptom and is DBGEN-gated,
while P3 names the actual failure class and is feasible today.
