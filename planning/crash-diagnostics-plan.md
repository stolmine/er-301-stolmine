# Crash diagnostics (dev debug mode) — implementation plan

*Spec for ledger item `infra-crash-diagnostics-debug-mode` and its split children.
Motivation: habitat has had many hardware-only C-side crashes (Ngoma differential-
switch, mi AAPCS/tree-vectorize, xform-target ABI) that leave ZERO evidence today
and each cost a multi-day bisect; firmware has had a handful ever. The Lua side is
already covered (xroot/Crash.lua → crash.log). The gap is C-side traps/hangs on
hardware. See docs/planning/todo-archive.md 'Crash Report' + habitat crash-pattern
memories.*

## 0. The load-bearing discovery: the primitives already exist (verified 2026-07-09)

The feature is mostly WIRING, not new low-level machinery:

1. **Register capture — SYS/BIOS ARM Exception module.** `ti/sysbios/family/arm/
   exc/Exception.h` already installs data-abort / prefetch-abort / undef handlers
   and captures a full `ExcContext` on any trap: r0–r12, sp, lr, pc, psr, plus the
   fault-status/address regs `dfsr/ifsr/dfar/ifar`, AND `threadType`/`threadHandle`/
   `threadStack` (so a report can name WHICH task faulted — audio vs UI, the single
   most useful fact in the habitat sagas). It exposes an `ExceptionHookFuncPtr`
   (`Exception.excHookFunc` in the .cfg) that runs with the ExcContext. We register
   a hook; we do NOT write raw ARM vectors. No exception config exists today →
   SYS/BIOS defaults, so this is purely additive.
2. **Module map — the dlopen registry.** `arch/am335x/hal/dynload/dlfcn.cpp:12`
   holds `std::map<std::string, od::ElfFile*> mLoaded` of every loaded package.
   Each `od::ElfFile` (arch/am335x/hal/dynload/ElfFile.h) has `mpTextSpace` (text
   base), `mTextSize`, `mpDataSpace`, `mDataSize`, `mFilename`. Iterating this map
   yields the runtime base of every package's code — the thing needed to turn a raw
   PC into `package.so + offset` and then a symbol via offline `addr2line`. This
   single artifact would have pointed straight at the trapping site in EVERY NEON
   saga. `mpTextSpace`/`mTextSize` are protected → add public accessors (ElfFile is
   internal firmware, not SWIG-exposed; appending methods is ABI-safe).
3. **Persisted report writer — xroot/Crash.lua.** Already appends a structured
   report (firmware version, boot/mount counts, message, traceback, recent log
   ring) to `front/crash.log`. The C-side capture extends this file/format; the Lua
   path is the model for the on-device dialog.
4. **Dev-mode toggle — `enableDevMode`** exists (xroot/Settings/init.lua:121),
   currently gated on `app.TESTING`. The debug/diagnostics arm is a sibling setting.

## 1. The hardware / emulator split (the crux)

The user's framing, and the design's spine: **the capture cannot be exercised in
the emulator** (the traps are hardware-only; the emu runs the "broken" code fine),
**but the UI, the report format, and the on-device viewer CAN** — via the headless
harness we just built. So the work splits into two independently-verifiable halves:

- **Capture half (am335x-only, user tests on hardware tomorrow):** exception hook,
  module-map dump, panic-buffer persistence, flight recorder. Verified by a
  deliberately-injected fault on the device producing a symbolizable report.
- **Presentation half (emu-verifiable NOW):** the debug-mode admin toggle, the
  crash-report data model + text format, the on-boot "a crash was captured" screen,
  and an admin viewer for past reports. Verified in the emu by INJECTING a synthetic
  crash report (no real trap needed) and driving the UI with tests/emu scripts.

The injection seam (item `infra-crash-diag-emu-inject`) is what makes the
presentation half testable without hardware: an emu-only affordance that drops a
canned crash record so the viewer/format render under the golden/trace harness.

## 2. The crash report format (shared contract)

One text schema, written by both the C hook (hardware) and the emu injector
(testing), read by the on-device viewer and by offline tooling. Extends the current
crash.log block. Fields:

```
---CRASH REPORT BEGIN
Schema: 2
Kind: data-abort | prefetch-abort | undef | lua | hang-watchdog
Time Since Boot: <s>
Firmware Version: <v>            Boot/Mount Count: <n>/<n>
Thread: audio | ui | <name>     (from ExcContext.threadType/Handle)
--- Registers ---               (C-side kinds only)
 pc=<hex> lr=<hex> sp=<hex> psr=<hex>
 dfsr=<hex> ifsr=<hex> dfar=<hex> ifar=<hex>
 r0..r12=<hex...>
--- Module Map ---              (kernel base + every loaded package)
 kernel            text=<base>..<end>
 <pkg>.so          text=<base>..<end>  data=<base>..<end>
--- Fault Resolution ---        (best-effort on-device)
 pc in <pkg>.so + <offset>   (or 'kernel + <offset>' or '?')
 lr in <pkg>.so + <offset>
--- Flight Recorder ---         (ring of recent trigger events)
 <t> insert sc.cv    <t> engine-switch plaits->clouds   ...
--- Lua ---                     (message + traceback if a Lua error)
--- Recent Log ---              (LogHistory ring, as today)
---CRASH REPORT END
```

The offline symbolication step (PC/offset → file:line) is a host tool
(`tools/symbolize_crash.py`): reads a report's module map + a directory of the
matching build `.so`/`.elf` files, runs `arm-none-eabi-addr2line`. Documented, not
auto-run on device.

## 3. Phases → ledger items (split the umbrella)

Keep `infra-crash-diagnostics-debug-mode` as the manual parent; add children:

- **`infra-crash-diag-format`** (docs/infra) — the §2 schema + tools/symbolize_crash.py.
  Verifiable offline (feed a sample report + sample .so, get file:line). Foundation.
- **`infra-crash-diag-exc-hook`** (infra, HARDWARE) — register the SYS/BIOS
  exception hook; on trap, capture ExcContext + module map into the panic buffer.
  Gated by debug mode. Verify: inject a fault on hardware, get a report with correct
  PC/registers/thread.
- **`infra-crash-diag-module-map`** (infra) — ElfFile accessors + a dlfcn enumerator
  that emits the module map. Partly emu-verifiable (the map renders in the emu even
  though no trap occurs there — the packages ARE loaded in emu).
- **`infra-crash-diag-panic-buffer`** (infra, HARDWARE) — reserved RAM region that
  survives warm reboot; hook writes it (card I/O from an abort context is unsafe),
  flushed to crash.log on next boot. Verify on hardware: crash, reboot, report present.
- **`infra-crash-diag-flight-recorder`** (infra) — ring of recent trigger events
  (unit insert, engine/mode switch, preset load — every historical crash was
  user-action-triggered). Emu-verifiable (events fire in emu).
- **`infra-crash-diag-debug-mode-ui`** (ui, EMU-VERIFIABLE) — admin toggle to arm
  diagnostics + on-boot "crash captured" screen + admin viewer for past reports.
  Verify in emu via harness.
- **`infra-crash-diag-emu-inject`** (emu, EMU-VERIFIABLE) — emu-only affordance to
  drop a synthetic crash record so the UI/format render under test without hardware.
  Enables the harness verification of the UI half.
- **`infra-crash-diag-hang-watchdog`** (infra, HARDWARE, LATER) — audio-thread
  heartbeat + WDT (arch/am335x/ti/am335x/wdt.h) to catch hangs (some sagas froze
  rather than trapped); on watchdog, snapshot + panic-buffer + reboot. Gate as a
  follow-on; the trap path lands first.

Zero-cost-when-off is mandatory on every hardware item (debug mode arms them; a
release build with debug off is byte-unaffected in the steady state).

## 4. Build order + who does what

1. **Format + module map + flight recorder + emu-inject + debug-mode UI**  — the
   emu-verifiable spine. One agent (Lua + emu + host tool + C++ enumerator). I verify
   in the emu with tests/emu scripts (inject → boot screen → viewer → golden/trace).
2. **Exception hook + panic buffer** — the hardware capture. One agent (C++ + sysbios
   .cfg). CANNOT be validated here; user tests on hardware tomorrow. Must build clean
   for both am335x (`make firmware ARCH=am335x`) and not regress the emu build.
3. **Hang watchdog** — deferred follow-on.

## 5. Constraints + risks

- **AM335x is patch-only**, but this is developer diagnostics serving habitat
  package dev on real hardware (the crashes don't reproduce in emu, so the headless
  substrate can't cover the capture half). Directly portable to the CM4 line (Linux
  coredumps + the same module-map convention).
- **Abort-context discipline:** the exception hook runs in a fault context — no
  malloc, no card I/O, no locks. It may only touch the reserved panic buffer and
  read the dlfcn map. All formatting/card-writing happens on the NEXT boot.

## 6. Implementation notes — emu-verifiable half (landed 2026-07-09)

The presentation spine (format, module-map, flight-recorder, emu-inject,
debug-mode-UI) is implemented and green in the headless emu (`tests/emu/40..44-
crash-diag-*.test`, full suite 9/9). Design decisions / deviations vs the sketch:

- **The emu does NOT share the am335x package loader.** am335x loads packages via
  the custom dlopen registry (`dlfcn.cpp` `mLoaded` of `od::ElfFile*`); the emu
  loads them as ordinary `.so`s through Lua `require` → the system linker, with no
  registry to walk. So the module map is provided behind an arch-neutral
  enumerator `od::enumerateModules()` (`hal/modulemap.h`), implemented per-arch:
  am335x over `mLoaded` (`dlfcn.cpp`), emu via `dl_iterate_phdr`
  (`arch/linux/hal/dynload.cpp`). Confirmed empirically: the emu map renders
  non-empty (kernel + 23 shared objects). `od::ElfFile` gained public
  `textBase/textSize/dataBase/dataSize` accessors (appended, ABI-safe).
- **C↔Lua without touching the SWIG surface.** The accessors reach Lua as
  `app.getModuleMap()` / `app.flightRecorder*` registered directly into the `app`
  table from `AppInterpreter::init` (`od/glue/CrashDiag.cpp`), so no `app.cpp.swig`
  regen and no ABI risk. Present in both arches.
- **Flight recorder is a C ring** (`od/extras/FlightRecorder`, N=32), armed by the
  `enableCrashDiagnostics` setting; `record()` is a no-op branch when disarmed
  (zero cost when off), and the sibling's abort hook can read it from C. Wired at
  three firmware-side seams: unit insert (`ChainBase:loadUnit`), unit/chain preset
  load, and quicksave load (`Persist`).
- **Emu-inject** is `CrashReport.injectSynthetic(kind)` (Lua, `app.EMULATION`-
  guarded), driven by the harness via the existing `lua` control command (no new
  `emu.*` function or `Control.cpp` command was needed). It writes a canned
  schema-v2 block (canned registers + the real emu module map + the flight
  recorder) plus a `front/crash.pending` marker.
- **On-boot notice** = a `front/crash.pending` marker whose presence triggers a
  dismissable `Message.Main` ("A crash was captured. See Admin > Crash Reports.")
  from `Application.init` via `CrashReport.checkPendingOnBoot()`; dismissing
  deletes the marker. The **viewer** is `AdminMode → Crash Reports`
  (`CrashReportViewer`, a report list + per-report detail scroll that reloads from
  `crash.log` on show).
- **Format contract** lives in `docs/CRASH_REPORT_FORMAT.md`; the offline
  symbolizer is `tools/symbolize_crash.py` (stdlib, env-configurable addr2line,
  `--selftest`). The Lua writer `CrashReport.write{...}` is the reference block and
  preserves the pre-schema labels so old readers cope.
- **Hardware half handshake:** the sibling consumes `od::enumerateModules()` (and
  added an abort-context-safe companion + `hal/crash.h` in `dlfcn.cpp`); its
  panic-buffer flush should emit `CrashReport.write`'s block shape and touch
  `front/crash.pending`.
- **Panic buffer survival:** must sit in a RAM region the warm reboot path
  (arch/am335x/hal/reboot.c) does not clear; confirm against the DDR init/zero.
- **Build both arches every change** (habitat lesson: emu-green ≠ hardware-green).
- **Audit first:** the archived sc.cv 'Crash Report' bug assumed a "crashdump from
  device" exists — confirm what (if anything) SYS/BIOS prints on abort today before
  building, so we extend rather than duplicate.

## 7. Hardware test procedure (capture half — run on am335x, staged 2026-07-10)

The capture half (`infra-crash-diag-exc-hook`, `infra-crash-diag-panic-buffer`)
CANNOT run in the emulator — the traps are hardware-only. This section is the
step-by-step to validate it on a real ER-301.

### 6.1 What ships in the firmware

Files (all built into `make firmware ARCH=am335x`, both builds verified clean;
`make emu` is untouched — the capture code is under `arch/am335x/` + `app/` which
the emu build does not compile):

- `hal/crash.h` — C API + abort-safe `PanicModuleEntry`/`panicEnumerateModules`.
- `arch/am335x/hal/crash/PanicBuffer.cpp` — the ARM exception hook
  (`stolCrashExcHook`), the panic record + CRC, the boot-time flush, and the
  section-6 fault injector.
- `arch/am335x/hal/dynload/dlfcn.cpp` — added `panicEnumerateModules()`, the
  allocation-free companion to the sibling's `od::enumerateModules()`.
- `arch/am335x/sysbios/common.cfg` — registers `Exception.excHookFunc =
  '&stolCrashExcHook'` (shared by the release + debug app builds; `enableDecode`
  left at its default `true`, so the existing UART register dump is preserved).
- `arch/am335x/sysbios/platforms/linkcmd_er301.xdt` — reserves a 16 KiB NOLOAD
  `.panicbuf` at the top of DDR (0xA0000000 − 0x4000 .. 0xA0000000) and caps od's
  runtime heap 16 KiB below it.
- `app/app.cpp` — calls `PanicBuffer_flushToLog()` after `Config_init`, and (only
  under `-DBUILDOPT_CRASH_TEST`) `PanicBuffer_checkTestTrigger()`.

The capture path is present in every build but **inert until armed**: the hook
returns immediately unless `od::flightRecorder().armed()` (the shared
`enableCrashDiagnostics` arm flag). A release build with diagnostics off is
unaffected at steady state.

### 6.2 Build the test firmware

1. Edit `scripts/app.mk` and uncomment `symbols += BUILDOPT_CRASH_TEST` (compiles
   the `1:/CRASH_TEST` boot-time self-trigger into `app_task`).
2. `make firmware ARCH=am335x`  → `release/am335x/er-301-*.zip`.
3. Install on the device (Firmware page / SD as usual). **Keep**
   `release/am335x/app/app.elf` and `release/am335x/mods/*/lib*.so` from THIS
   build for offline symbolication — they must match the running binary.

(Re-comment the flag and rebuild for a normal firmware once testing is done.)

### 6.3 Inject a fault

Front card = the removable card the ER-301 mounts as `1:`.

1. On a computer, create a file named `CRASH_TEST` in the front card's root.
   - Empty or any first byte → **data-abort** (write to unmapped 0xF0000000).
   - First byte `u` → **undefined-instruction** trap.
2. Insert the card and boot the ER-301.

On boot `app_task` sees `1:/CRASH_TEST`, deletes it (one-shot, so there is no
reboot loop), arms diagnostics + auto-reboot, and calls `Crash_testTrap()`, which
faults. The SYS/BIOS exception handler dumps the registers over UART (unchanged),
then `stolCrashExcHook` snapshots the fault into the panic buffer, cache-cleans
it, and warm-reboots (WDT). DRAM keeps its charge across the warm reset, so the
buffer survives; the next boot's `PanicBuffer_flushToLog()` formats it to
`1:/crash.log`, drops `1:/crash.pending`, and clears the panic magic.

Alternative (no rebuild): once the sibling wires an interactive trigger or a Lua
console is available in dev mode, call `Crash_testTrap(0)` directly. To hit the
**audio** thread specifically (the highest-value habitat case), a deliberately
faulting DSP unit is the right injector; the card-file path traps on the main
task, which still exercises the whole capture→persist→flush pipeline.

### 6.4 Expected result

- The device reboots once by itself, then boots normally.
- The sibling's on-boot notice ("A crash was captured. See Admin > Crash
  Reports.") appears if the presentation half is installed (it keys off
  `1:/crash.pending`).
- Pull the front card. `1:/crash.log` ends with a schema-v2 block, e.g.:

```
---CRASH REPORT BEGIN
Schema: 2
Kind: data-abort
Time Since Boot: 3.512s
Firmware Version: 0.7.0-stolmine.9.5.2.x
Boot Count: ?
Mount Count: ?
Thread: app (handle=0x8xxxxxxx)
--- Registers ---
 pc=8xxxxxxx lr=8xxxxxxx sp=4xxxxxxx psr=600000xx
 dfsr=00000805 ifsr=00000000 dfar=f0000000 ifar=00000000
 r0=... r1=... r2=... r3=... r4=... r5=... r6=...
 r7=... r8=... r9=... r10=... r11=... r12=...
--- Module Map ---
 kernel                   text=0
 x:/ER-301/.../libcore.so text=a0nnnnnn..a0mmmmmm  data=...
 ...
--- Fault Resolution ---
 pc in kernel + 0x<off>
 lr in kernel + 0x<off>
--- Flight Recorder ---
 (empty)
--- Recent Log ---
Recent Log Messages:
 (not captured C-side; see flight recorder above)
---CRASH REPORT END
```

For a data-abort, `dfar` should read `0xf0000000` (the address `Crash_testTrap`
wrote). For an undef, `Kind: undef` and `pc` points at the `.word 0xe7f000f0`.

### 6.5 Symbolize offline

```sh
python3 tools/symbolize_crash.py 1:/crash.log \
    --build-dir release/am335x/app \
    --addr2line arm-none-eabi-addr2line
```

`--build-dir release/am335x/app` resolves kernel PCs against `app.elf`; add the
package `.so`s (point `--build-dir` at a directory containing both `app.elf` and
`release/am335x/mods/*/lib*.so`, or run once per artifact set) to resolve package
PCs. Each `pc`/`lr` prints `<module> + 0x<off>` and, if `addr2line` is on PATH,
`function at file:line`. For the injected data-abort the pc resolves inside
`Crash_testTrap`.

### 6.6 Runtime-unverified assumptions — CONFIRM these tomorrow

Static tracing got the build green and the logic reasoned, but a real trap was
never observed. Flag these while testing:

1. **DDR panic buffer survives the WDT warm reset (THE load-bearing assumption).**
   The buffer is a NOLOAD `.panicbuf` at 0x9FFFC000..0xA0000000: not zeroed by C
   startup (only `.bss` is), not claimed by od's heap (`unused_memory` capped 16
   KiB below), not written by the boot loader (NOLOAD, and the app image loads low
   in DDR). The warm reset keeps DRAM powered and the SBL's EMIF re-init reconfig
   -ures the controller without scrubbing high DRAM. If a report DOES appear in
   `crash.log` after the self-reboot, this is confirmed. If it does NOT: the region
   is being scrubbed — the magic+CRC makes that fail-safe (no bogus report), and
   the fallback is to move `.panicbuf` into OCMC SRAM, but note OCMC is the SBL's
   own workspace so it is a *weaker* candidate, not stronger, despite the plan's
   initial guess. Check the UART log for `PanicBuffer: flushed ...` vs silence.
2. **Cache write-back reaches DRAM before the reset.** The hook calls
   `Cache_wbInv` on `.panicbuf` before `reboot()`. If the report is corrupt/absent
   only intermittently, suspect the cache clean (try `Cache_wbInvAll`).
3. **The WDT warm reset actually reloads + reboots cleanly from this fault
   context.** `reboot()` is the proven `app.reboot()` / 3-dial-chord path, but it
   has not been exercised from *inside* an abort. If the device hangs instead of
   rebooting, the fallback is to leave `Crash_setAutoReboot(false)` and reboot via
   the 3-dial chord (also a warm reset, so the buffer still survives).
4. **`Task_getEnv` in the abort context returns the thread name.** Expected
   `Thread: app` for the card-file test (main task) and `Thread: audio` for a real
   audio-task trap. An HWI-context trap shows `Thread: hwi (handle=0x0)` (no env) —
   that is correct, not a bug.
5. **`panicEnumerateModules` reading the live `mLoaded` map is safe.** True for the
   common DSP/NEON trap (heap intact). A fault *during* `dlopen` (mid map-insert)
   could see a partial tree and nested-fault; the `g_inHook` guard + magic-written
   -last design make that fail-safe (invalid record, no bogus report) but it means
   no module map for that rare case.
6. **`f_open`/`Card_mount(1)` at the flush point.** Confirm the report reaches the
   card. If `1:` is absent at boot, the flush leaves the magic set and retries on a
   later boot with a card in — verify by booting once cardless, then with a card.

### 6.7 RESULT — trap path bench-VALIDATED 2026-07-11 (fw 9.5.2.46)

All six assumptions above CONFIRMED on hardware. Injected data-abort → panic
buffer survived the WDT warm reset (assumption 1 HELD) → flushed schema-2 block to
`front/crash.log` on next boot with exact fault state (`dfar=0xf0000000`,
`r2=0xf0000000`, `r3=0xdeadbeef`); `pc=0x801fe2b8` symbolized to
`Crash_testTrap` (PanicBuffer.cpp:683) via `arm-none-eabi-addr2line` against the
`.46` `app.elf`; module map bounded (`kernel 80000000..804f191c`), `lr` above text
end resolved to `?`; version stamped `.46` from the record's capture-time field.
Reproduced across two runs. Ledger: exc-hook, panic-buffer, oneshot-guard,
fwversion-capture-time, kernel-fallback-bound all flipped done (commit 1d37d77).

ONE residual defect: partial register capture (`sp==pc`, `psr/r1/r8-r11=0xffffffff`)
— localized UPSTREAM of our hook (SYS/BIOS bios 6.46 A8 abort frame; `excDumpContext`
reads the identical `ExcContext` fields), tracked in
`crashdiag-fix-partial-register-capture`. Diagnostic-essential set intact.

--------------------------------------------------------------------------------

## 8. Hang watchdog — design pass (2026-07-11)

The trap path catches faults. It does NOT catch **hangs** — the habitat freezes
(mi AAPCS livelocks, differential-switch stalls, NaN storms) where the audio code
loops or blocks forever instead of trapping, leaving zero evidence. This is the
last open capability of the debug-mode umbrella and the hardest, because a hang
hands us no `ExcContext`: by definition the stuck code will not run our capture.

### 8.1 Resolved architecture (the facts that make this tractable)

Investigated 2026-07-11:

- **Audio DSP runs in a Task, not a HWI.** `arch/am335x/hal/audio.c`: `taskAudio`
  is a `Task_create` at `TASK_PRIORITY_AUDIO = 11` (hal/priorities.h), driven by
  EDMA ping-pong completion **Events** (`Event_pend` on `pingDone`/`pongDone`).
  `Audio_callback()` — which runs every package unit's `process()`, i.e. the exact
  habitat trap/hang sites — executes **in that task context**. This is the single
  most important fact: the hang we care about is a **Task-context** hang with
  interrupts still enabled.
- **Scheduler order is HWI > Swi > Task.** So a monitor running in **Swi context**
  (a SYS/BIOS `Clock` function) preempts a spinning audio Task (pri 11) with no raw
  timer/HWI programming. The default SYS/BIOS Clock tick already exists; no free
  DMTIMER is needed.
- **`reboot()` is a bare WDT1 register poke** (`startWatchDogTimer(1000)`,
  arch/am335x/hal/reboot.c), already proven callable from the abort context, so the
  monitor may call it too.
- **The persistence spine is done and bench-proven:** panic buffer + next-boot
  flush + flight recorder + the reserved `Kind: hang-watchdog` schema slot. The hang
  path REUSES all of it; only capture *acquisition* is new.

### 8.2 Mechanism

1. **Heartbeat.** A monotonic counter `g_audioFrames` bumped once per
   `Audio_callback` in `taskAudio`. Plus an `g_audioRunning` flag set when the
   McASP/EDMA stream is started and cleared when it is stopped (audio.c start/stop
   seams). The flag is ESSENTIAL: a legitimately-stopped stream also freezes the
   counter (`Event_pend` blocks forever), and without the gate that reads as a
   false hang.
2. **Monitor.** A periodic SYS/BIOS `Clock` function (≈100 ms), created + started
   ONLY when hang diagnostics are armed. Each tick it samples `(g_audioFrames,
   g_audioRunning)`. If `g_audioRunning` and the frame counter has not advanced for
   K consecutive ticks (≈250 ms — dozens of frames' worth at 48 kHz), declare a
   hang. Runs in Swi context, so it preempts the stuck audio Task.
3. **Snapshot.** Build a `PanicRecord` with `faultType = HANG` from the audio Task:
   best-effort `pc`, `sp`, and a **raw stack window** (new fixed-size field, see
   8.4) copied from the task's saved stack, plus the existing module map + flight
   recorder + capture-time `fwVersion`. Set the one-shot `g_captured` latch,
   `Cache_wbInv` the buffer, then `reboot()`. Identical persistence to the trap path.
4. **Flush + view.** The existing next-boot flush prints the block (`Kind:
   hang-watchdog` is already in the format contract), the on-boot notice fires, and
   the admin viewer renders it. Offline: `symbolize_crash.py` scans the stack window
   for in-`.text` return addresses against the module map to reconstruct a backtrace
   (see 8.4), so we get a call chain, not just one PC.

### 8.3 Coverage — be explicit about what a hang monitor can and cannot catch

| Hang class | Caught? | How / why |
|---|---|---|
| Livelock / infinite loop / NaN storm in `Audio_callback` (Task ctx, IRQs on) | **Yes, full** | Clock Swi preempts; the preempting HWI already saved the task's FULL register frame on its stack → complete capture. THE common habitat case. |
| Deadlock / blocked-forever (mutex, `Event_pend` never satisfied) | **Yes, partial** | Heartbeat goes stale; snapshot the task's saved switch-frame → shows the block site (callee-saved regs + return PC into `Event_pend`/`Semaphore_pend`), enough to say "deadlocked here". |
| Spin inside a driver **HWI** (EDMA/McASP/SD ISR) | **No (MVP)** | A Swi cannot preempt a HWI. Rare for habitat (their hangs are in DSP task code). A phase-2 high-INTC-priority HWI monitor could, but out of MVP scope. |
| Hard spin with **interrupts disabled** | **No capture** | The Clock tick can't fire. Only the hardware WDT backstop (8.5, phase 2) recovers the device — a reset with no snapshot. Documented gap. |

The MVP catches the two classes that actually cost the multi-day habitat bisects.

### 8.4 The one genuinely new/tricky piece: acquiring a hung Task's state

A hung task's context differs by sub-case, and reconstructing exact register frames
from SYS/BIOS TCB internals is fragile:

- A **preempted (spinning)** task has a FULL exception frame (r0-r12/pc/psr) on its
  own stack, left by the HWI that preempted it.
- A **blocked** task has only the callee-saved switch frame (r4-r11/sp/lr) saved by
  `Task_switch`.

Rather than branch on bios-internal frame layouts, the MVP captures a **raw stack
window** (proposal: 256 bytes from the task's saved SP) plus the saved SP itself,
and defers interpretation to the offline symbolizer, which **scans the window for
words that land in any module's `.text` range** (it already has the module map) and
prints them as a candidate backtrace, innermost first. This is robust to both
sub-cases, needs no bios-version-specific struct reads, and yields a call chain
instead of a single frame. The device-side `pc` is best-effort (from the saved
frame when we can identify it, else left 0 and the stack scan carries the load).

`PanicRecord` grows by one fixed `uint8_t stackWindow[256]` + `uint32_t
stackWindowSp` (the trap path can populate it too, for free backtraces there).
Budget is fine: current record ≈ 0x2228 of the 0x4000 `.panicbuf` reservation, so
+0x104 is comfortably within the `static_assert`.

### 8.5 Zero-cost-when-off + the IRQ-off backstop (phasing)

- **Off cost:** the heartbeat is a single store per audio frame (optionally gated
  behind `g_hangArmed` for byte-exact parity when off). The Clock monitor instance
  only exists while armed. A release build with diagnostics off is unaffected at
  steady state — same guarantee as the trap path.
- **Phase 2 (follow-on, recovery-only):** arm hardware **WDT1** at a long timeout
  (≈2 s) when hang diagnostics are on, petted by the monitor Clock function. If
  interrupts are disabled (the monitor itself can't run), WDT1 hardware-resets the
  device — recovery WITHOUT capture, closing the "device is just frozen forever"
  UX at least. Needs care: `reboot()` already reprograms WDT1, so the live-watchdog
  and reset-trigger uses must be reconciled. Kept OUT of MVP (it captures nothing;
  the value is capture).

### 8.6 Bench trigger + verification

Mirror the trap path's one-file-drop ergonomics: extend `BUILDOPT_CRASH_TEST` so a
`CRASH_TEST` whose first byte is `'h'` makes `Audio_callback` enter an infinite
loop on the next frame (a deliberate livelock). Verify: drop the file, boot the
test firmware, confirm the device auto-reboots within the monitor window and the
next boot shows a `Kind: hang-watchdog` report whose stack-window scan resolves to
the injected loop in the audio path. HARDWARE-ONLY (hangs, like traps, don't
reproduce in the emu — but the report FORMAT + viewer + symbolizer stack-scan are
emu-testable via a synthetic hang record through the existing injector).

### 8.7 Build order

1. **Heartbeat + `g_audioRunning` gate** (audio.c) — trivial, isolated.
2. **Clock monitor + hang snapshot** (new `hal/crash` code reusing PanicRecord) +
   the `stackWindow` field + `Kind: hang` populated by the existing flush.
3. **Symbolizer stack-scan** (`tools/symbolize_crash.py`) + synthetic hang record
   in the emu injector for format/viewer testing.
4. **`BUILDOPT_CRASH_TEST` `'h'` trigger** + bench verify.
5. **(Phase 2, later)** WDT1 IRQ-off backstop.

Open decisions to confirm during implementation: the exact audio.c start/stop seams
for the `g_audioRunning` flag; the K-tick threshold vs the real frame period; and
whether to gate the heartbeat store when off (recommended: yes, for byte-exact
off-parity).
