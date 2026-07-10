#ifndef _hal_crash_h
#define _hal_crash_h

// [stol:infra-crash-diag-panic-buffer][stol:infra-crash-diag-exc-hook]
//
// Hardware crash-capture facility for the am335x firmware. Two cooperating
// halves, both implemented in arch/am335x/hal/crash/PanicBuffer.cpp:
//
//   1. An ARM exception hook (stolCrashExcHook) registered as
//      Exception.excHookFunc in arch/am335x/sysbios/common.cfg. On a
//      data-abort / prefetch-abort / undef trap it runs in a FAULT CONTEXT
//      (no malloc, no card I/O, no locks) and does nothing but snapshot the
//      fault into a reserved RAM "panic buffer": fault kind, pc/lr/sp/psr,
//      dfsr/ifsr/dfar/ifar, r0-r12, the faulting thread identity, the loaded
//      module map, and the flight-recorder ring. Gated behind the shared
//      diagnostics arm flag (od::flightRecorder().armed()); inert when off.
//
//   2. A boot-time flush (PanicBuffer_flushToLog) called once the filesystem
//      is up. If the panic buffer holds a valid captured report it is formatted
//      into the schema-v2 crash-report block (planning/crash-diagnostics-plan.md
//      section 2) and appended to front/crash.log, then the magic is cleared.
//
// The panic buffer lives in a reserved NOLOAD region at the top of DDR
// (__panic_buffer_start__ .. __panic_buffer_end__, see linkcmd_er301.xdt) that
// survives a warm reboot: the capture path warm-reboots (WDT) so DRAM keeps its
// charge, the boot loader only writes the app image low in DDR, and C startup
// zeros only .bss. A magic + version + CRC header lets the next boot tell a
// valid captured report from garbage, so a scrubbed region is fail-safe (no
// report, never a bogus one).

#ifdef __cplusplus
extern "C"
{
#endif

#include <stdint.h>
#include <stdbool.h>

  // ---- Panic-buffer lifecycle ------------------------------------------------

  // Optional early init (currently only logs the region/arm state). Safe to
  // call, but not required for capture or flush to work.
  void PanicBuffer_init(void);

  // True if the reserved region currently holds a valid captured report
  // (correct magic, version, and CRC over the payload).
  bool PanicBuffer_valid(void);

  // Wipe the magic so a future boot does not re-flush the same report.
  void PanicBuffer_clear(void);

  // If a valid captured report is present, format it as a schema-v2 block and
  // append it to front/crash.log, then clear the magic. Mounts the front card
  // ("1:") itself if needed (and restores the prior mount state). Returns 1 if a
  // report was flushed, 0 otherwise. Call once at boot after the card stack and
  // globalConfig are initialized (see app/app.cpp, after Config_init).
  int PanicBuffer_flushToLog(void);

  // ---- Arm / behavior control ------------------------------------------------

  // Convenience mirror of od::flightRecorder().arm()/armed() — the shared
  // diagnostics arm flag also gates the exception hook. Arming is normally done
  // from Lua via app.flightRecorderArm(true) (wired to the enableCrashDiagnostics
  // admin setting by the sibling UI item).
  void Crash_arm(bool on);
  bool Crash_armed(void);

  // When armed, a captured fault triggers a warm reboot so the DDR panic buffer
  // survives (a cold power-cycle would lose it). Default: enabled. Disable to
  // keep the classic abort behavior (spin + 3-dial-chord reboot); then the
  // buffer only survives if the user reboots via the 3-dial chord (also warm).
  void Crash_setAutoReboot(bool on);
  bool Crash_autoReboot(void);

  // ---- Abort-safe module-map reader (implemented in dlfcn.cpp) ---------------

  // Fixed-size, allocation-free module-map entry. The sibling's
  // od::enumerateModules() (hal/modulemap.h) returns std::vector<std::string>
  // which allocates and is NOT safe from an abort context, so the hook uses this
  // POD reader instead. Entry 0 is always the kernel (textBase 0 == not
  // relocated; a kernel PC maps directly onto kernel.elf for addr2line), matching
  // the sibling's enumerateModules() convention so tools/symbolize_crash.py reads
  // both uniformly.
  // TODO(crash-diag integration): once the sibling's enumerator grows an
  // allocation-free variant, retire panicEnumerateModules and call that.
  typedef struct
  {
    // [stol:crashdiag-review-nits] 128 chars so a full package install path is
    // not truncated: the host tool (tools/symbolize_crash.py) matches artifacts
    // by basename, and a truncated tail can drop the basename entirely.
    char path[128];     // "kernel" or the package .so path (truncated to fit)
    uintptr_t textBase; // runtime base of the code segment (0 == not relocated)
    uint32_t textSize;  // bytes (0 == unknown)
    uintptr_t dataBase; // runtime base of the data segment (0 == unknown)
    uint32_t dataSize;  // bytes (0 == unknown)
  } PanicModuleEntry;

  // Fills 'out' with up to maxEntries entries (kernel first). Returns the count
  // written. Reads the dlopen registry only; no allocation, no locks.
  int panicEnumerateModules(PanicModuleEntry *out, int maxEntries);

  // ---- Hardware fault injection (for the section-6 test procedure) -----------

  // Deliberately trigger an ARM trap so the capture path can be exercised on
  // hardware (it cannot be reproduced in the emulator). kind: 0 = data-abort
  // (write to an unmapped address), 1 = undefined instruction. Does not return.
  // Arms diagnostics + auto-reboot first so a single call produces a report.
  void Crash_testTrap(int kind);

  // Boot-time self-trigger for the hardware test: if the front card holds a file
  // named "CRASH_TEST", delete it (one-shot, so the next boot does not re-trap)
  // and call Crash_testTrap(). The file's first byte selects the kind ('u' =
  // undef, anything else = data-abort). Wired into app_task only when the
  // firmware is built with -DBUILDOPT_CRASH_TEST, so production is unaffected.
  void PanicBuffer_checkTestTrigger(void);

#ifdef __cplusplus
}
#endif

#endif // _hal_crash_h
