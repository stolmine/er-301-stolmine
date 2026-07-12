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
