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
  // undef, 'h' = hang-watchdog livelock, anything else = data-abort). Wired into
  // app_task only when the firmware is built with -DBUILDOPT_CRASH_TEST, so
  // production is unaffected.
  void PanicBuffer_checkTestTrigger(void);

  // ---- Hang watchdog [stol:infra-crash-diag-hang-watchdog] -------------------
  //
  // Catches HANGS (livelocks / blocked-forever audio code) that never trap, so
  // the exception hook above never runs. A Swi-context SYS/BIOS Clock samples an
  // audio-thread heartbeat; if the heartbeat stalls while the stream is running,
  // it snapshots the audio task (best-effort pc/sp + a raw stack window) into the
  // SAME panic buffer and warm-reboots. See planning/crash-diagnostics-plan.md
  // section 8. am335x-only capture; the emu path (emu/hal/audio.c) neither
  // defines nor reads the seam globals below.
  //
  // Heartbeat seam between the audio task (arch/am335x/hal/audio.c, the producer)
  // and the monitor (arch/am335x/hal/crash/HangWatchdog.cpp, the consumer):
  extern volatile uint32_t g_audioFrames; // bumped once per Audio_callback when armed
  extern volatile bool g_audioRunning;    // true between Audio_start() and Audio_stop()
  extern volatile bool g_hangArmed;       // monitor armed; also gates the heartbeat store
  extern void *g_audioTask;               // Task_Handle of the audio task (set in Audio_init)

  // Arm / disarm the hang monitor. Creates the Clock on the first arm and
  // Clock_start/Clock_stop thereafter, so a never-armed build never creates it
  // (zero cost when off). Idempotent. Called from the arm choke points (Crash_arm
  // and the Lua app.flightRecorderArm binding) so the flight-recorder arm also
  // arms hang capture. A weak no-op default (od/glue/CrashDiag.cpp) is linked on
  // builds without the am335x monitor (the emu), so shared callers always link.
  void Crash_hangArm(bool on);

  // True once a record has been sealed (one-shot latch shared with the trap
  // path). The monitor consults it to avoid re-declaring after a hang is sealed.
  bool Crash_captured(void);

  // Build a HANG PanicRecord from the audio task (best-effort pc/sp + a 256-byte
  // raw stack window), reusing the trap path's record/CRC/module-map/flight-
  // recorder/one-shot-latch machinery, then Cache_wbInv + warm-reboot. Called by
  // the Clock monitor when a stall is declared. Runs in Swi context: allocation-
  // free, bounded, snapshots the audio task's own stack only.
  void PanicBuffer_captureHang(void);

  // ---- Audio-Event pend-queue guard [stol:crashdiag-object-guard-event] ------
  //
  // Closes the attribution gap of the Anamnesis insert data-abort: the corruption
  // clobbers the audio Event's pend queue, but the fault only surfaces ~0.2s
  // later when the next Event_post walks the wrecked queue and traps. This guard
  // validates the pendQ doubly-linked sentinel invariant in the audio ISR BEFORE
  // Event_post runs; on a breach it seals a PANIC_FAULT_GUARD record (kind
  // "event-guard-breach": first-seen wallclock + the corrupted next/prev links +
  // the per-task stacks) and warm-reboots, exactly like the trap path. am335x
  // capture only; the emu presentation half is exercised via the synthetic
  // injector (xroot/CrashReport.lua) + tools/symbolize_crash.py.

  // Publish the audio Event handle so the guard can locate its pendQ header.
  // Called once from Audio_init (arch/am335x/hal/audio.c) after Event_create.
  // A null / out-of-DDR handle simply leaves the guard disabled (no-op check).
  void PanicBuffer_setAudioEvent(void *eventHandle);

  // Validate the audio Event's pendQ sentinel; on a breach, seal a
  // PANIC_FAULT_GUARD record + warm-reboot. Bounded, allocation-free, one-shot,
  // callable from the EDMA Hwi or the Swi hang tick. The CALLER gates on
  // g_hangArmed (one predicted branch when disarmed) so it is zero cost when off;
  // the function also re-checks armed()/captured() defensively.
  void PanicBuffer_checkAudioEventGuard(void);

  // Livelock flag for the BUILDOPT_CRASH_TEST 'h' trigger: set by
  // PanicBuffer_checkTestTrigger, read by the audio task, which spins forever on
  // its next frame so the monitor can catch a deliberate hang. Defined only in
  // the crash-test build; unreferenced (and undefined) otherwise.
  extern volatile bool g_crashTestHang;

  // ---- Heap pressure [stol:crashdiag-heap-stats] -----------------------------
  //
  // Heap analog of the P0 stack high-water: put heap pressure into every crash
  // report so a footprint / exhaustion bug (the confirmed Anamnesis root cause)
  // is visible at a glance. The am335x Heap_* wrappers (arch/am335x/hal/heap.c)
  // maintain these plain globals on each allocation; the capture path only READS
  // them (globals-only == abort-safe, the P0 lesson: no sbrk, no mallinfo, no
  // free-list walk in the fault/Swi context). The wrapper updates are gated on
  // g_hangArmed (a plain bool load) so a disarmed build pays nothing at steady
  // state.
  //
  // NOTE (deviation from the P3 plan's sbrk formula, detail in
  // arch/am335x/hal/heap.c): this newlib malloc is NOT sbrk-backed (sbrk does not
  // link -- no `end` symbol) and __unused_memory is od::BigHeap's region, so
  // g_heapArenaHighWater is measured as the PEAK live (in-use) bytes of the newlib
  // heap via malloc_usable_size() accounting in the wrappers, not sbrk(0)-base.
  // g_heapCeiling stays Heap_getUnusedMemorySize() per the plan.
  //
  // am335x-only: the newlib arena + sbrk exist only there, so these are DEFINED
  // in arch/am335x/hal/heap.c and READ only by arch/am335x/hal/crash/
  // PanicBuffer.cpp. The emu neither defines nor reads them (its presentation
  // half is driven by the CrashReport.lua synthetic injector), so declaring the
  // externs here does not burden the emu link.
  //
  // Tier 1 (heap pressure, updated on each SUCCESSFUL allocation):
  extern volatile uint32_t g_heapCeiling;        // Heap_getUnusedMemorySize()
  extern volatile uint32_t g_heapArenaHighWater; // peak live newlib bytes (see note)
  extern volatile uint32_t g_heapAllocCount;     // running successful-alloc count
  // Tier 2 (last allocation FAILURE, record-only; no reboot on a benign NULL):
  extern volatile uint32_t g_heapLastFailSize;  // requested bytes of the last fail
  extern volatile uint32_t g_heapLastFailPc;    // caller pc (__builtin_return_address)
  extern volatile uint32_t g_heapLastFailArena; // arena high-water at the fail
  extern volatile uint32_t g_heapFailCount;     // running alloc-fail count

#ifdef __cplusplus
}
#endif

#endif // _hal_crash_h
