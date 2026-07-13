# ER-301 crash report format (schema v2)

Canonical, shared contract for the crash-diagnostics facility
(`planning/crash-diagnostics-plan.md` §2). One text schema is written by **both**:

- the **hardware** capture half (the AM335x SYS/BIOS ARM exception hook flushing a
  warm-reboot-surviving panic buffer to `front/crash.log` on the next boot), and
- the **emu** injector (`CrashReport.injectSynthetic`, for testing the
  presentation half without a real trap),

and is read by:

- the on-device viewer (`AdminMode` → **Crash Reports**), and
- the offline host tool `tools/symbolize_crash.py`.

It **extends** the pre-schema `front/crash.log` block previously written by
`xroot/Crash.lua`: the old `Firmware Version:`, `Boot Count:`, `Mount Count:`,
`Error Message:`, and `Recent Log Messages:` labels are preserved so existing
readers still cope. New readers key off `Schema: 2`.

## Block layout

Each report is delimited by `---CRASH REPORT BEGIN` / `---CRASH REPORT END`
(unchanged from v1, so a `crash.log` may contain a mix of v1 and v2 blocks).

```
---CRASH REPORT BEGIN
Schema: 2
Kind: data-abort | prefetch-abort | undef | lua | hang-watchdog | event-guard-breach
 *** STACK <name> BLOWN ***          (0+ banner lines, only if a stack is blown/near-full)
 *** STACK <name> NEAR-FULL (<pct>%) ***
 *** EVENT GUARD BREACH (audio pendQ corrupted) ***   (only if kind=event-guard-breach)
 *** HEAP NEAR-CEILING (<pct>%) ***   (only if arena high-water >= 90% of ceiling)
Time Since Boot: <s>s
Firmware Version: <v>
Boot Count: <n>
Mount Count: <n>
Thread: audio | ui | <name>          (from ExcContext threadType/Handle on hw)
--- Registers ---                    (C-side kinds only; omitted for kind=lua)
 pc=<hex> lr=<hex> sp=<hex> psr=<hex>
 dfsr=<hex> ifsr=<hex> dfar=<hex> ifar=<hex>
 r0=<hex> r1=<hex> ... r12=<hex>
--- Module Map ---                   (kernel + every loaded package)
 kernel                   text=<lo>..<hi>  data=<lo>..<hi>
 <pkg>.so                 text=<lo>..<hi>  data=<lo>..<hi>
--- Fault Resolution ---             (best-effort, on-device, symbol-free)
 pc in <pkg>.so + 0x<off>            (or 'kernel + 0x<off>' or '?')
 lr in <pkg>.so + 0x<off>
--- Stacks ---                       (per-task + ISR stack high-water; trap AND hang)
 <name>          base=<hex> size=<n> used=<n> (<pct>%) canary=<ok|BLOWN>
 isr             base=<hex> size=<n> used=<n> (<pct>%) canary=<ok|BLOWN>
--- Heap ---                         (heap pressure; present in every capture on hw)
 ceiling=<n> arena-highwater=<n> (<pct>%) allocs=<n>
 last-alloc-fail: size=<n> pc=<hex> (count=<n>)   (only if an alloc has failed)
--- Event Guard ---                  (kind=event-guard-breach only; corrupted audio pendQ)
 pendQ=<hex> next=<hex> prev=<hex> reason=<hex>
 reason: next-badptr prev-badptr next-link prev-link   (only the failed rules)
Hang State: running (spin) | blocked (kind=hang-watchdog only; how to read sp)
--- Stack Window ---                 (kind=hang-watchdog only; raw hung-task stack)
 sp=<hex> bytes=<n>
 <addr>: <w0> <w1> <w2> <w3>
 <addr>: <w0> <w1> <w2> <w3>
--- Flight Recorder ---              (ring of recent trigger events; ' (empty)')
 <t>s  insert sc.cv
 <t>s  quickload slot 1
--- Lua ---                          (kind=lua only)
Error Message:
<message>
<traceback>
--- Recent Log ---
Recent Log Messages:
<LogHistory ring, one line each>
---CRASH REPORT END
```

### Section notes

- **Module Map.** Emitted by `app.getModuleMap()` (C, `od/glue/CrashDiag.cpp`),
  which formats the arch-neutral `od::enumerateModules()` enumerator
  (`hal/modulemap.h`). Each line is `<path>  text=<lo>..<hi>[  data=<lo>..<hi>]`.
  Bases/extents are hex. A **non-relocated kernel** renders as `text=0` (its PCs
  map directly onto the kernel `.elf`); a relocated object (all emu `.so`s, all
  AM335x packages) renders a real `<lo>..<hi>` range.
  - AM335x: enumerated over the dlopen registry (`arch/am335x/hal/dynload/
    dlfcn.cpp`, the `mLoaded` map of `od::ElfFile*`). Lists the ER-301 packages.
  - Emu: enumerated with `dl_iterate_phdr` (`arch/linux/hal/dynload.cpp`). Lists
    the emu main program (labeled `kernel`) plus every loaded shared object.

- **Fault Resolution.** A best-effort, symbol-free lookup done on-device
  (`CrashReport.resolveAddress`): finds the module whose `text` range contains the
  address and prints `<module> + 0x<offset>`, or `?` if none. The real
  symbolication (offset → `file:line`) is offline (below); the device never runs
  `addr2line`.

- **Stacks.** Per-task and ISR/system-stack high-water + canary, present for
  **both** trap and hang captures (`crashdiag-stack-highwater`). One line per task
  (up to 16), then the `isr` line. `base` is the stack's lowest address (ARM
  stacks are full-descending, growing DOWN toward it), `size`/`used` are bytes,
  `(<pct>%)` is `used/size`, and `canary=BLOWN` means the guard word at `base` was
  overwritten (an overflow wrote down through the stack base) versus `ok`. The
  high-water is computed at capture time by scanning the SYS/BIOS `0xbe`
  stack-fill (`Task.initStackFlag`, required) from `base` upward for the first
  non-fill word; the ISR line comes from `Hwi_getStackInfo`. When any stack is
  blown (broken canary) or near-full (`used >= 90%`), a prominent
  ` *** STACK <name> BLOWN ***` / ` *** STACK <name> NEAR-FULL (<pct>%) ***`
  banner is emitted near the **top** of the block (right after `Kind:`) so the
  prime suspect is unmissable, and `tools/symbolize_crash.py` leads its output
  with that stack **before** the register/backtrace dump (the overflow is the
  corruption ROOT; the fault site is only the downstream detection). The per-task
  numbers exist only on am335x hardware; the emu injector
  (`injectSynthetic("stacks")`) emits a canned blown-MAIN block so the
  format/viewer/symbolizer are testable without a trap.
- **Heap.** Heap pressure, present in **every** capture (`crashdiag-heap-stats`),
  the heap analog of `--- Stacks ---`. The am335x `Heap_*` wrappers
  (`arch/am335x/hal/heap.c`) wrap newlib `malloc` over the `__unused_memory_start__
  ..__unused_memory_end__` arena and maintain plain globals on each allocation;
  the capture only READS them (globals-only == abort-safe: no `sbrk`, no
  `mallinfo`, no free-list walk in the fault/Swi context, the free list being
  exactly what a heap-exhaustion bug corrupts). `ceiling` is the static arena
  size; `arena-highwater` is the peak `sbrk(0) - arena_start` footprint (newlib
  rarely returns the break, so this is a monotonic exhaustion proxy) and `(<pct>%)`
  is `arena-highwater/ceiling`; `allocs` is a running successful-alloc count. When
  the arena high-water reaches **>= 90%** of the ceiling a prominent
  ` *** HEAP NEAR-CEILING (<pct>%) ***` banner is emitted near the **top** of the
  block (right after `Kind:`), and `tools/symbolize_crash.py` leads its output with
  it. The confirmed Anamnesis root cause is heap exhaustion / over-footprint, so a
  near-ceiling arena is the prime signal. The optional ` last-alloc-fail:` line
  appears only when an allocation has returned NULL (`heapFailCount > 0`): it names
  the last failure's requested `size`, the caller `pc` (`__builtin_return_address`,
  symbolizable via the Module Map into e.g. `libanamnesis.so`), and a running
  `count`. A NULL return is recorded **only**, never rebooted, so a benign NULL the
  caller handles does not disturb the device. The updates are gated on the shared
  armed flag (`g_hangArmed`, a plain bool load) so a disarmed build is unaffected.
  The per-alloc numbers exist only on am335x hardware; the emu injector
  (`injectSynthetic("heap")`) emits a canned near-ceiling block so the
  format/viewer/symbolizer are testable without hardware.
- **Event Guard.** `kind=event-guard-breach` only (`crashdiag-object-guard-event`).
  The audio Event's pend queue is a SYS/BIOS doubly-linked-list sentinel; the
  audio ISR validates its invariant (`next`/`prev` mapped + 4-aligned, and each
  back-pointer points at the header) BEFORE `Event_post` walks it. On a breach it
  seals this record with the FIRST-SEEN time (the `Time Since Boot:` line) instead
  of trapping ~0.2s later in `Event_post` — turning "corruption detected in
  `Event_post`" into "audio pendQ corrupted, first seen at T". `pendQ` is the
  watched header address; `next`/`prev` are the corrupted links; `reason` is a
  bitmask (`0x1` next-badptr, `0x2` prev-badptr, `0x4` next-link, `0x8` prev-link)
  followed by a decoded ` reason:` line. The registers are best-effort (`pc=0`
  because the corruptor is long gone; `lr` is the ISR detection site); the
  load-bearing evidence is this section plus the `--- Stacks ---` section (which,
  on the Anamnesis case, also surfaces the clobbered Task_Object). The per-breach
  CAPTURE is am335x-hardware-only; the emu injector
  (`injectSynthetic("event-guard-breach")`) emits a canned block so the
  format/viewer/symbolizer are testable without the write.
- **Hang State.** `kind=hang-watchdog` only. `running (spin)` means the audio task
  was executing when the monitor fired, so `sp` and the Stack Window are the LIVE
  interrupted context (from `Hwi_getTaskSP()`) and the window is the real spin call
  chain. `blocked` means the audio task was not running (a deadlock), so `sp` is the
  saved block site (from `Task_stat`). Read the Stack Window accordingly.
- **Stack Window.** `kind=hang-watchdog` only. A hang hands the capture no
  register frame (by definition the stuck code never runs the trap hook), so the
  monitor copies a 256-byte raw window from the hung audio task's stack (the LIVE
  interrupted SP for a spin, the saved block site for a deadlock; see Hang State)
  and the report serializes it for offline backtrace reconstruction. First line is
  ` sp=<hex> bytes=<n>` (the address the window was copied from and its valid
  length); each following line is ` <addr>: <w0> <w1> <w2> <w3>` — the address
  prefix, then four little-endian 32-bit stack words (16 bytes/line). Lines are in
  **ascending address == innermost-frame-first** order, so a straight read of the
  words is a call-order candidate backtrace. `tools/symbolize_crash.py` scans the
  words for ones that land in a bounded module `.text` range and prints them as
  the candidate backtrace (a stack word only counts on a confident bounded match,
  so junk words — stack pointers, zeros — are dropped). The device-side `pc`/`lr`
  are best-effort (typically `0` → `?` for a hang); the stack scan carries the
  load.

- **Flight Recorder.** Emitted by `app.flightRecorderText()`. Ring of the last
  32 crash-trigger events (unit insert, unit/chain preset load, quicksave load),
  each `<t>s  <label>`. Empty ⇒ ` (empty)`. Recording is gated by the
  `enableCrashDiagnostics` setting (zero cost when off).

## Offline symbolication

`tools/symbolize_crash.py` (stdlib only) reads a report's **Module Map** +
**Registers** (and, for a hang, the **Stack Window**), resolves each `pc`/`lr` —
and each in-`.text` stack-window word — to `<module> + offset`, then to
`file:line` via `addr2line` against a directory of matching build artifacts.

```sh
# resolve against the build .so/.elf files
python3 tools/symbolize_crash.py front/crash.log --build-dir path/to/build

# the addr2line binary is configurable (default arm-none-eabi-addr2line)
CRASH_ADDR2LINE=arm-none-eabi-addr2line python3 tools/symbolize_crash.py report.txt -b build/

# self-contained sanity check (no report, no cross toolchain needed)
python3 tools/symbolize_crash.py --selftest
```

If `addr2line` is absent the tool degrades gracefully: it still prints the
`package + offset` resolution, just without `file:line`. Artifacts are matched by
basename (`core.so`, `app.elf`, …); `kernel` matches `app.elf`/`emu.elf`/the first
`.elf` found.

## Emu injection (testing the presentation half)

Because the hardware traps do not reproduce in the emu, the on-boot notice, the
report format, and the admin viewer are exercised by **injecting** a synthetic
report:

```lua
require("CrashReport").injectSynthetic("data-abort")     -- app.EMULATION only
require("CrashReport").injectSynthetic("hang-watchdog")  -- adds a Stack Window
require("CrashReport").injectSynthetic("stacks")         -- adds a --- Stacks --- section + BLOWN banner
require("CrashReport").injectSynthetic("event-guard-breach") -- adds an --- Event Guard --- section + banner
require("CrashReport").injectSynthetic("heap")           -- adds a --- Heap --- section + NEAR-CEILING banner
```

This writes a canned schema-v2 report (canned registers + the **real** emu module
map + the current flight recorder) to `front/crash.log` and drops a
`front/crash.pending` marker. `CrashReport.checkPendingOnBoot()` (called from
`Application.init`) then shows the on-boot "a crash was captured" notice. The
headless harness drives this end-to-end: see `tests/emu/40..43-crash-diag-*.test`.

## Pending marker

`front/crash.pending` is a one-line marker whose **presence** means "an
unacknowledged crash report exists". Written by the emu injector and (on hardware)
the panic-buffer flush; consumed by the on-boot notice, which deletes it on
dismissal.

## Notes for the hardware capture half

- Call `od::enumerateModules()` (or the abort-context-safe companion in
  `dlfcn.cpp`) to fill the Module Map; the format above is what the viewer + host
  tool expect. Keep the `<path>  text=<lo>..<hi>  data=<lo>..<hi>` column shape.
- The panic-buffer flush should write a schema-v2 block and touch
  `front/crash.pending`. The Lua writer `CrashReport.write{...}` is the reference
  implementation of the block; a C flush should match its section order/labels.
- `Thread:` is the single most useful field in the habitat sagas — populate it
  from `ExcContext.threadType`/`threadHandle` (audio vs ui).
- **Hang captures** (`Kind: hang-watchdog`) come from the Swi-context Clock
  monitor (`arch/am335x/hal/crash/HangWatchdog.cpp`), not the ARM exception hook:
  an audio-thread heartbeat stalls while the stream runs, the monitor snapshots
  the hung task into the SAME panic buffer (best-effort `sp` + the 256-byte
  **Stack Window**, `pc` left `0`), then warm-reboots. It reuses the trap path's
  record/CRC/module-map/flight-recorder/one-shot-latch persistence verbatim. See
  `planning/crash-diagnostics-plan.md` §8.
