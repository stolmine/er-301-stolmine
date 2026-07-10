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
- **Panic buffer survival:** must sit in a RAM region the warm reboot path
  (arch/am335x/hal/reboot.c) does not clear; confirm against the DDR init/zero.
- **Build both arches every change** (habitat lesson: emu-green ≠ hardware-green).
- **Audit first:** the archived sc.cv 'Crash Report' bug assumed a "crashdump from
  device" exists — confirm what (if anything) SYS/BIOS prints on abort today before
  building, so we extend rather than duplicate.
