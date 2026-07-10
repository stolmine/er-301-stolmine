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
Kind: data-abort | prefetch-abort | undef | lua | hang-watchdog
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

- **Flight Recorder.** Emitted by `app.flightRecorderText()`. Ring of the last
  32 crash-trigger events (unit insert, unit/chain preset load, quicksave load),
  each `<t>s  <label>`. Empty ⇒ ` (empty)`. Recording is gated by the
  `enableCrashDiagnostics` setting (zero cost when off).

## Offline symbolication

`tools/symbolize_crash.py` (stdlib only) reads a report's **Module Map** +
**Registers**, resolves each `pc`/`lr` to `<module> + offset`, then to `file:line`
via `addr2line` against a directory of matching build artifacts.

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
require("CrashReport").injectSynthetic("data-abort")  -- app.EMULATION only
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
