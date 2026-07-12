// [stol:infra-crash-diag-panic-buffer][stol:infra-crash-diag-exc-hook]
//
// HARDWARE crash capture for am335x. See hal/crash.h for the overview.
//
// This half CANNOT be exercised in the emulator (the traps are hardware-only),
// so it is written to a static-analysis + on-hardware-test discipline; the
// hardware test procedure is planning/crash-diagnostics-plan.md section 6.

#include <hal/crash.h>
#include <hal/log.h>
#include <hal/timing.h>
#include <hal/reboot.h>
#include <hal/card.h>
#include <hal/fileops.h>
#include <od/config.h>
#include <od/extras/FlightRecorder.h>

#include <string.h>
#include <stdio.h>
#include <stddef.h>

#include <ti/sysbios/BIOS.h>
#include <ti/sysbios/knl/Task.h>
#include <ti/sysbios/family/arm/exc/Exception.h>
#include <ti/sysbios/family/arm/a8/intcps/Hwi.h> // [stol:crashdiag-hang-spin-pc] Hwi_getTaskSP
#include <ti/sysbios/hal/Cache.h>

#include <hal/fatfs/ff.h>

extern "C"
{

  // Reserved NOLOAD region at the very top of DDR (see
  // arch/am335x/sysbios/platforms/linkcmd_er301.xdt). Not zeroed by C startup
  // (only .bss is), not claimed by od's runtime heap (unused_memory is capped
  // 0x4000 bytes below the top of DDR), not written by the boot loader (NOLOAD).
  extern uint8_t __panic_buffer_start__[];
  extern uint8_t __panic_buffer_end__[];

  // Kernel text extent (see linkcmd_er301.xdt). Copied into module-map entry 0
  // so panicResolve can bound the "kernel" attribution instead of swallowing any
  // unmatched 0x8xxxxxxx address. [stol:crashdiag-fix-kernel-fallback-bound]
  extern uint8_t __kernel_text_start__[];
  extern uint8_t __kernel_text_end__[];

  // ---------------------------------------------------------------------------
  // Panic record layout (lives at __panic_buffer_start__)
  // ---------------------------------------------------------------------------

#define PANIC_MAGIC 0x53544C43u // 'STLC' — stolmine crash
  // Binary panic-record LAYOUT version. Bumped whenever the PanicRecord struct
  // changes, so a record written by an OLD firmware that survived a warm-reboot
  // reflash is rejected as invalid (version mismatch) rather than misread with
  // the new layout. This is distinct from the TEXT crash-report schema (the
  // literal "Schema: 2" line in the flushed block, the shared contract in
  // docs/CRASH_REPORT_FORMAT.md) which is unchanged by binary-layout bumps.
  //   v3: added char fwVersion[] (capture-time firmware) + bounded kernel entry.
  //   v4: added stackWindow[]/stackWindowSp for the hang watchdog (section 8).
  //   v5: added hangRunning (spin vs blocked) for the live-SP hang capture.
#define PANIC_VERSION 5u
#define PANIC_MAX_MODULES 48
#define PANIC_MAX_FR_EVENTS 32
#define PANIC_FR_LABEL_LEN 48
#define PANIC_THREAD_NAME_LEN 16
#define PANIC_FW_VERSION_LEN 32

  // [stol:infra-crash-diag-hang-watchdog] Sentinel faultType for a hang capture.
  // The trap path stores an Exception_Type (small values: 0x11 supervisor, 0x17
  // prefetch, 0x18 data, 0x1b undef); this ASCII 'HANG' sentinel cannot collide,
  // so panicKindString maps it to "hang-watchdog" without disturbing the enum.
#define PANIC_FAULT_HANG 0x484E4721u // 'HNG!'

  // Raw stack window copied from a hung task (section 8.4). The offline
  // symbolizer scans it for in-.text return addresses to reconstruct a candidate
  // backtrace, robust to both the preempted (full frame) and blocked (switch
  // frame) sub-cases without parsing bios-internal frame layouts.
#define PANIC_STACK_WINDOW_BYTES 256

  typedef struct
  {
    float t;
    char label[PANIC_FR_LABEL_LEN];
  } PanicFrEvent;

  typedef struct
  {
    uint32_t magic; // PANIC_MAGIC when a valid report is present
    uint32_t crc;   // CRC32 over [version .. end of struct]

    uint32_t version; // PANIC_VERSION

    // Fault identity
    uint32_t faultType; // Exception_Type (0x18 data, 0x17 prefetch, 0x1b undef)
    uint32_t pc, lr, sp, psr;
    uint32_t dfsr, ifsr, dfar, ifar;
    uint32_t r[13];

    // Faulting thread
    uint32_t threadType;   // BIOS_ThreadType
    uint32_t threadHandle; // Task_Handle / Swi_Handle pointer, else 0
    char threadName[PANIC_THREAD_NAME_LEN];

    float wallclock; // seconds since boot at fault time

    // [stol:crashdiag-fix-fwversion-capture-time] Firmware version captured at
    // FAULT time, not flush time. The record survives a warm reboot (including a
    // reflash), so printing the flushing binary's version would mislabel an old
    // crash with the new firmware. Filled from FIRMWARE_VERSION in the hook.
    char fwVersion[PANIC_FW_VERSION_LEN];

    // Module map
    uint32_t moduleCount;
    PanicModuleEntry modules[PANIC_MAX_MODULES];

    // Flight recorder ring (chronological, oldest first)
    uint32_t frCount;
    PanicFrEvent fr[PANIC_MAX_FR_EVENTS];

    // [stol:infra-crash-diag-hang-watchdog] Raw stack window for a hang capture
    // (section 8.4). stackWindowSp is the address the window was copied FROM (so
    // the report and any future tool can locate it); stackWindowLen is how many
    // bytes are valid (<= PANIC_STACK_WINDOW_BYTES, clamped to the task stack).
    // Zero stackWindowSp => no window present (the trap path leaves it zero).
    uint32_t stackWindowSp;
    uint32_t stackWindowLen;
    uint8_t stackWindow[PANIC_STACK_WINDOW_BYTES];

    // [stol:crashdiag-hang-spin-pc] Hang sub-case: 1 = the audio task was RUNNING
    // when the monitor fired (a SPIN; sp is the LIVE interrupted SP from
    // Hwi_getTaskSP), 0 = the audio task was BLOCKED (a deadlock; sp is the
    // Task_stat saved block site). Lets the reader interpret the backtrace.
    // Zero for the trap path.
    uint32_t hangRunning;
  } PanicRecord;

  // [stol:crashdiag-review-nits] The reserved .panicbuf region is 16 KiB (see
  // arch/am335x/sysbios/platforms/linkcmd_er301.xdt). Guard so a future
  // PANIC_MAX_MODULES bump, a wider PanicModuleEntry::path, or a new field
  // cannot silently overflow the region.
  static_assert(sizeof(PanicRecord) <= 0x4000,
                "PanicRecord exceeds the 16 KiB reserved .panicbuf region");

  // ---------------------------------------------------------------------------
  // Arm / behavior state (plain globals — no constructors, zero-cost when off)
  // ---------------------------------------------------------------------------

  static bool g_autoReboot = true;
  static volatile int g_inHook = 0;
  // [stol:crashdiag-fix-oneshot-guard] Set once a record is sealed. Capture is
  // ONE-SHOT: after a successful seal the device is rebooting, so the hook must
  // never run again — otherwise a nested fault in the SYS/BIOS Error_raise tail
  // (which runs on possibly-corrupt state within the ~30ms WDT window) would
  // re-enter and memset/overwrite the real sealed record with a boring one.
  static volatile bool g_captured = false;

  void Crash_arm(bool on)
  {
    od::flightRecorder().arm(on);
    // [stol:infra-crash-diag-hang-watchdog] Same choke point arms hang capture,
    // so the Clock monitor exists exactly when diagnostics are armed. Idempotent.
    Crash_hangArm(on);
  }

  // [stol:infra-crash-diag-hang-watchdog] One-shot latch accessor for the hang
  // monitor (g_captured is file-static). Lets the Clock tick skip re-declaring
  // once any record — trap or hang — has been sealed.
  bool Crash_captured(void)
  {
    return g_captured;
  }

  bool Crash_armed(void)
  {
    return od::flightRecorder().armed();
  }

  void Crash_setAutoReboot(bool on)
  {
    g_autoReboot = on;
  }

  bool Crash_autoReboot(void)
  {
    return g_autoReboot;
  }

  // ---------------------------------------------------------------------------
  // CRC32 (bitwise, table-less) — no dependencies, safe from an abort context.
  // ---------------------------------------------------------------------------

  static uint32_t panicCrc32(const uint8_t *p, uint32_t n)
  {
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < n; i++)
    {
      crc ^= p[i];
      for (int b = 0; b < 8; b++)
      {
        uint32_t mask = -(crc & 1u);
        // [stol:crashdiag-review-nits] NOTE: 0xEDB88720 is NON-STANDARD (the
        // standard reversed CRC-32 polynomial is 0xEDB88320). It is harmless
        // here because the same function both seals and verifies, but an
        // off-device reimplementer must use THIS value, not the textbook one.
        crc = (crc >> 1) ^ (0xEDB88720u & mask);
      }
    }
    return ~crc;
  }

  static uint32_t panicPayloadLen(void)
  {
    // CRC covers everything after the magic+crc header words.
    return (uint32_t)(sizeof(PanicRecord) - offsetof(PanicRecord, version));
  }

  static PanicRecord *panicRecord(void)
  {
    return (PanicRecord *)__panic_buffer_start__;
  }

  // ---------------------------------------------------------------------------
  // The exception hook — runs in a FAULT CONTEXT.
  //
  // Discipline honored here (planning/crash-diagnostics-plan.md section 5):
  //   * no malloc / new (only plain memcpy/strncpy into the reserved region)
  //   * no card I/O (that is deferred to the next-boot flush)
  //   * no locks (Task_getEnv and the dlopen-map read are lock-free accessors)
  //   * bounded work, reentrancy-guarded (g_inHook) so a nested fault while
  //     writing the buffer cannot recurse.
  //
  // SYS/BIOS has already dumped the register context over UART/USB
  // (Exception.enableDecode, which we deliberately leave at its default 'true')
  // BEFORE this hook is called, so the existing live diagnostic is preserved;
  // we only ADD the persisted capture.
  // ---------------------------------------------------------------------------

  void stolCrashExcHook(Exception_ExcContext *ctx)
  {
    if (g_captured || g_inHook)
    {
      // Already sealed a record (one-shot — the device is rebooting), or a
      // nested fault re-entered while we are mid-capture. Either way, bail and
      // preserve whatever is already in the buffer; do not recurse or overwrite.
      return;
    }
    g_inHook = 1;

    // Gate: only capture when diagnostics are armed. When disarmed this is the
    // whole cost on a (already fatal) trap: one predicted branch, then return —
    // the classic abort path (UART dump + _exit spin) is untouched.
    if (!od::flightRecorder().armed())
    {
      g_inHook = 0;
      return;
    }

    PanicRecord *rec = panicRecord();

    // Deterministic payload: zero the whole record first so unused module/FR
    // slots do not carry stale DDR into the CRC.
    memset(rec, 0, sizeof(PanicRecord));

    rec->version = PANIC_VERSION;

    rec->faultType = (uint32_t)ctx->type;
    rec->pc = (uint32_t)(uintptr_t)ctx->pc;
    rec->lr = (uint32_t)(uintptr_t)ctx->lr;
    rec->sp = (uint32_t)(uintptr_t)ctx->sp;
    rec->psr = (uint32_t)(uintptr_t)ctx->psr;
    rec->dfsr = (uint32_t)(uintptr_t)ctx->dfsr;
    rec->ifsr = (uint32_t)(uintptr_t)ctx->ifsr;
    rec->dfar = (uint32_t)(uintptr_t)ctx->dfar;
    rec->ifar = (uint32_t)(uintptr_t)ctx->ifar;
    rec->r[0] = (uint32_t)(uintptr_t)ctx->r0;
    rec->r[1] = (uint32_t)(uintptr_t)ctx->r1;
    rec->r[2] = (uint32_t)(uintptr_t)ctx->r2;
    rec->r[3] = (uint32_t)(uintptr_t)ctx->r3;
    rec->r[4] = (uint32_t)(uintptr_t)ctx->r4;
    rec->r[5] = (uint32_t)(uintptr_t)ctx->r5;
    rec->r[6] = (uint32_t)(uintptr_t)ctx->r6;
    rec->r[7] = (uint32_t)(uintptr_t)ctx->r7;
    rec->r[8] = (uint32_t)(uintptr_t)ctx->r8;
    rec->r[9] = (uint32_t)(uintptr_t)ctx->r9;
    rec->r[10] = (uint32_t)(uintptr_t)ctx->r10;
    rec->r[11] = (uint32_t)(uintptr_t)ctx->r11;
    rec->r[12] = (uint32_t)(uintptr_t)ctx->r12;

    rec->threadType = (uint32_t)ctx->threadType;
    rec->threadHandle = (uint32_t)(uintptr_t)ctx->threadHandle;

    // Cheap thread name: tasks carry their name in env (see hal/log.cpp).
    if (ctx->threadType == BIOS_ThreadType_Task && ctx->threadHandle)
    {
      const char *name = (const char *)Task_getEnv((Task_Handle)ctx->threadHandle);
      if (name)
      {
        strncpy(rec->threadName, name, PANIC_THREAD_NAME_LEN - 1);
      }
    }

    rec->wallclock = wallclock();

    // [stol:crashdiag-fix-fwversion-capture-time] Stamp the RUNNING firmware
    // version now, at fault time. memset above already NUL-filled the field, so
    // a bounded strncpy leaves it terminated (and "?" at flush if unset).
#ifdef FIRMWARE_VERSION
    strncpy(rec->fwVersion, FIRMWARE_VERSION, sizeof(rec->fwVersion) - 1);
#endif

    // Module map — allocation-free reader over the dlopen registry.
    rec->moduleCount = (uint32_t)panicEnumerateModules(rec->modules, PANIC_MAX_MODULES);

    // [stol:crashdiag-fix-kernel-fallback-bound] Entry 0 is the kernel by
    // convention (hal/crash.h / panicEnumerateModules), emitted with textBase 0.
    // Give it the REAL kernel text extent so panicResolve bounds the "kernel"
    // attribution: an unmatched PC (package missing from the map, mid-dlopen,
    // >48 modules) then resolves to "?" instead of a false "kernel + 0x8xxxxxxx".
    if (rec->moduleCount > 0)
    {
      rec->modules[0].textBase = (uintptr_t)__kernel_text_start__;
      rec->modules[0].textSize =
          (uint32_t)((uintptr_t)__kernel_text_end__ - (uintptr_t)__kernel_text_start__);
    }

    // Flight-recorder ring (fixed struct, no heap — safe to read here).
    {
      od::FlightRecorder &fr = od::flightRecorder();
      int n = fr.count();
      if (n > PANIC_MAX_FR_EVENTS)
      {
        n = PANIC_MAX_FR_EVENTS;
      }
      for (int i = 0; i < n; i++)
      {
        const od::FlightRecorder::Event *e = fr.at(i);
        if (!e)
        {
          continue;
        }
        rec->fr[rec->frCount].t = e->timestamp;
        strncpy(rec->fr[rec->frCount].label, e->label, PANIC_FR_LABEL_LEN - 1);
        rec->frCount++;
      }
    }

    // Seal it: CRC over the payload, then the magic (magic last so a torn write
    // never looks valid).
    rec->crc = panicCrc32((const uint8_t *)&rec->version, panicPayloadLen());
    rec->magic = PANIC_MAGIC;

    // [stol:crashdiag-fix-oneshot-guard] Record is now sealed (magic written
    // last). Latch capture OFF before we touch anything else: from here on any
    // nested fault (in Cache_wbInv, reboot(), or the SYS/BIOS Error_raise tail)
    // returns immediately at the hook entry and cannot overwrite this record.
    // We deliberately do NOT reset g_inHook — the device is rebooting; there is
    // nothing to re-enable.
    g_captured = true;

    // DDR is cached: push the record out of D-cache to DRAM so it survives the
    // reset (a warm reset drops cache lines without writeback).
    Cache_wbInv((Ptr)__panic_buffer_start__, (SizeT)sizeof(PanicRecord), (Bits16)Cache_Type_ALL, (Bool)TRUE);

    // Warm-reboot so the DDR buffer survives (a cold power-cycle would lose it).
    // Gated so the classic behavior is preserved when auto-reboot is disabled.
    if (g_autoReboot)
    {
      reboot(); // WDT warm reset; returns, then fires a few ticks later
    }
  }

  // ---------------------------------------------------------------------------
  // [stol:infra-crash-diag-hang-watchdog] Hang capture — runs in Swi context.
  //
  // Called by the Clock monitor (HangWatchdog.cpp) once the audio heartbeat has
  // stalled while the stream is running. Builds a HANG PanicRecord reusing the
  // trap path's record / CRC / module-map / flight-recorder / one-shot-latch
  // machinery, then cache-cleans + warm-reboots exactly like stolCrashExcHook.
  //
  // The module-map / flight-recorder / seal blocks are DELIBERATELY DUPLICATED
  // from stolCrashExcHook rather than refactored into a shared helper: the trap
  // path is bench-validated (section 6.7) and cannot be re-verified in the emu,
  // so it is left byte-for-byte untouched. Swi context is more permissive than an
  // abort context, but the same discipline holds: no malloc, no card I/O, no
  // locks; only the reserved panic buffer, the lock-free dlopen map, and the
  // audio task's OWN stack are read, all bounded.
  // ---------------------------------------------------------------------------

  void PanicBuffer_captureHang(void)
  {
    if (g_captured || g_inHook)
    {
      return; // one-shot: a record is already sealed / being sealed.
    }
    g_inHook = 1;

    if (!od::flightRecorder().armed())
    {
      g_inHook = 0;
      return;
    }

    PanicRecord *rec = panicRecord();
    memset(rec, 0, sizeof(PanicRecord));
    rec->version = PANIC_VERSION;
    rec->faultType = PANIC_FAULT_HANG;

    // Best-effort task state. A hang hands us no ExcContext, so pc/psr/registers
    // stay zero and the raw stack window (below) carries the backtrace load.
    Task_Handle t = (Task_Handle)g_audioTask;
    if (t)
    {
      rec->threadType = (uint32_t)BIOS_ThreadType_Task;
      rec->threadHandle = (uint32_t)(uintptr_t)t;
      const char *name = (const char *)Task_getEnv(t);
      if (name)
      {
        strncpy(rec->threadName, name, PANIC_THREAD_NAME_LEN - 1);
      }

      // Stack bounds are static (valid always) via the public Task_stat; its
      // `sp` (= tsk->context, the last context-switch-OUT SP) is the fallback.
      Task_Stat st;
      Task_stat(t, &st);
      uintptr_t base = (uintptr_t)st.stack;
      uintptr_t top = base + (uintptr_t)st.stackSize;

      // [stol:crashdiag-hang-spin-pc] Pick the SP by the hang sub-case. This runs
      // in the Swi posted by the periodic tick Hwi, so Task_self() is the task
      // that Hwi PREEMPTED:
      //   * preempted task IS the audio task  => it was RUNNING, i.e. SPINNING.
      //     Its LIVE stack pointer is Hwi_getTaskSP(): the SP the FIRST Hwi saved
      //     on the task->ISR switch (set once, not overwritten by nested Hwis,
      //     reset only on return to the task), so it is valid through this Swi and
      //     points at the live spin frames. Task_stat's saved SP is STALE here (it
      //     is the last yield, e.g. a prior frame's Event_pend) and is what made
      //     the first bench capture resolve to Idle/scheduler frames.
      //   * preempted task is something else  => the audio task is BLOCKED
      //     (deadlock): it is NOT running, so Hwi_getTaskSP() is another task's SP.
      //     Task_stat's saved SP IS the block site -- use it.
      bool spinning = (Task_self() == t);
      uintptr_t sp = (uintptr_t)st.sp;
      if (spinning)
      {
        uintptr_t live = (uintptr_t)Hwi_getTaskSP();
        if (live >= base && live < top) // trust it only inside the audio stack
        {
          sp = live;
        }
      }
      rec->sp = (uint32_t)sp;
      rec->hangRunning = spinning ? 1u : 0u;

      // Window UPWARD from sp with a small margin below. On a full-descending
      // stack the current frame's locals + every caller's return PC live at
      // addresses >= sp; below sp is unused. So [sp-16, sp-16+N) captures the
      // live call chain (spin case) or the block site + its callers (blocked
      // case), innermost-first by ascending address. Clamp to [base, top) and
      // copy only the task's own stack so this stays fault-safe from Swi context.
      if (top > base && sp >= base && sp < top)
      {
        const uintptr_t margin = 16;
        uintptr_t start = (sp >= base + margin) ? sp - margin : base;
        uintptr_t avail = top - start;
        uint32_t n = (avail < PANIC_STACK_WINDOW_BYTES)
                         ? (uint32_t)avail
                         : PANIC_STACK_WINDOW_BYTES;
        memcpy(rec->stackWindow, (const void *)start, n);
        rec->stackWindowSp = (uint32_t)start;
        rec->stackWindowLen = n;
      }
    }

    rec->wallclock = wallclock();

#ifdef FIRMWARE_VERSION
    strncpy(rec->fwVersion, FIRMWARE_VERSION, sizeof(rec->fwVersion) - 1);
#endif

    // Module map — allocation-free reader over the dlopen registry.
    rec->moduleCount = (uint32_t)panicEnumerateModules(rec->modules, PANIC_MAX_MODULES);
    if (rec->moduleCount > 0)
    {
      rec->modules[0].textBase = (uintptr_t)__kernel_text_start__;
      rec->modules[0].textSize =
          (uint32_t)((uintptr_t)__kernel_text_end__ - (uintptr_t)__kernel_text_start__);
    }

    // Flight-recorder ring (fixed struct, no heap — safe to read here).
    {
      od::FlightRecorder &fr = od::flightRecorder();
      int n = fr.count();
      if (n > PANIC_MAX_FR_EVENTS)
      {
        n = PANIC_MAX_FR_EVENTS;
      }
      for (int i = 0; i < n; i++)
      {
        const od::FlightRecorder::Event *e = fr.at(i);
        if (!e)
        {
          continue;
        }
        rec->fr[rec->frCount].t = e->timestamp;
        strncpy(rec->fr[rec->frCount].label, e->label, PANIC_FR_LABEL_LEN - 1);
        rec->frCount++;
      }
    }

    // Seal (magic last), latch the one-shot, cache-clean, warm-reboot — identical
    // persistence to the trap path.
    rec->crc = panicCrc32((const uint8_t *)&rec->version, panicPayloadLen());
    rec->magic = PANIC_MAGIC;
    g_captured = true;

    Cache_wbInv((Ptr)__panic_buffer_start__, (SizeT)sizeof(PanicRecord), (Bits16)Cache_Type_ALL, (Bool)TRUE);

    if (g_autoReboot)
    {
      reboot(); // WDT warm reset; DDR keeps its charge so the buffer survives.
    }
  }

  // ---------------------------------------------------------------------------
  // Validity / clear
  // ---------------------------------------------------------------------------

  bool PanicBuffer_valid(void)
  {
    PanicRecord *rec = panicRecord();
    // Fresh boot: cache is cold, but invalidate to be certain we read DRAM.
    Cache_inv((Ptr)__panic_buffer_start__, (SizeT)sizeof(PanicRecord), (Bits16)Cache_Type_ALL, (Bool)TRUE);
    if (rec->magic != PANIC_MAGIC || rec->version != PANIC_VERSION)
    {
      return false;
    }
    uint32_t crc = panicCrc32((const uint8_t *)&rec->version, panicPayloadLen());
    return crc == rec->crc;
  }

  void PanicBuffer_clear(void)
  {
    PanicRecord *rec = panicRecord();
    rec->magic = 0;
    Cache_wbInv((Ptr)__panic_buffer_start__, (SizeT)sizeof(rec->magic), (Bits16)Cache_Type_ALL, (Bool)TRUE);
  }

  void PanicBuffer_init(void)
  {
    logInfo("PanicBuffer: region %p..%p (%u bytes), record %u bytes, armed=%d",
            (void *)__panic_buffer_start__, (void *)__panic_buffer_end__,
            (unsigned)(__panic_buffer_end__ - __panic_buffer_start__),
            (unsigned)sizeof(PanicRecord), (int)Crash_armed());
  }

  // ---------------------------------------------------------------------------
  // Boot-time flush → schema-v2 block appended to front/crash.log
  // ---------------------------------------------------------------------------

  static const char *panicKindString(uint32_t type)
  {
    switch (type)
    {
    case Exception_Type_DataAbort:
      return "data-abort";
    case Exception_Type_PreAbort:
      return "prefetch-abort";
    case Exception_Type_UndefInst:
      return "undef";
    // [stol:infra-crash-diag-hang-watchdog] Not an Exception_Type; the sentinel
    // the hang monitor stores in faultType. Maps to the reserved schema Kind.
    case PANIC_FAULT_HANG:
      return "hang-watchdog";
    // [stol:crashdiag-review-nits] "swi"/"unknown" are outside the documented
    // Kind enum in docs/CRASH_REPORT_FORMAT.md (data-abort | prefetch-abort |
    // undef | lua | hang-watchdog). Kept because parsers tolerate an unknown
    // Kind and these only appear for exotic traps; do not treat as the enum.
    case Exception_Type_Supervisor:
      return "swi";
    default:
      return "unknown";
    }
  }

  // Resolve a code address to "<module> + <offset>" using the captured map.
  //
  // [stol:crashdiag-fix-kernel-fallback-bound] Every entry — INCLUDING the
  // kernel (entry 0, now carrying its real bounded text extent) — is matched by
  // its [textBase, textBase+textSize) range. An address inside NO entry resolves
  // to "?"; there is no whole-0x8xxxxxxx "kernel" fallback (packages also live in
  // DDR, so that fallback mislabelled a missing-from-map package PC as kernel).
  //
  // Offset semantics differ by relocation, matching tools/symbolize_crash.py:
  //   * kernel  — linked at its runtime address (0x80000000), NOT relocated, so
  //               addr2line against app.elf wants the ABSOLUTE address; offset
  //               is the addr itself.
  //   * package — linked at 0 and loaded into the od heap, so offset is
  //               addr - textBase.
  // The kernel entry is identified by its "kernel" path (enumerator entry 0).
  static void panicResolve(PanicRecord *rec, uint32_t addr, char *out, size_t n)
  {
    for (uint32_t i = 0; i < rec->moduleCount; i++)
    {
      PanicModuleEntry *m = &rec->modules[i];
      if (m->textSize > 0 && addr >= m->textBase &&
          addr < m->textBase + m->textSize)
      {
        bool isKernel = (strcmp(m->path, "kernel") == 0);
        unsigned off = isKernel ? (unsigned)addr
                                : (unsigned)(addr - (uint32_t)m->textBase);
        snprintf(out, n, "%s + 0x%x", m->path, off);
        return;
      }
    }
    snprintf(out, n, "?");
  }

  // Append a NUL-terminated string to the open file. Returns true only if the
  // entire string was written (FRESULT ok AND all bytes accepted) so the caller
  // can refuse to clear the panic magic on a partial/failed write.
  // [stol:crashdiag-fix-flush-error-handling]
  static bool panicPut(FIL *f, const char *s)
  {
    UINT want = (UINT)strlen(s);
    UINT bw = 0;
    FRESULT r = f_write(f, s, want, &bw);
    return r == FR_OK && bw == want;
  }

  int PanicBuffer_flushToLog(void)
  {
    if (!PanicBuffer_valid())
    {
      return 0;
    }

    PanicRecord *rec = panicRecord();

    // Front card ("1:") is mounted lazily by the Lua boot flow; mount it here if
    // needed and restore the prior state afterward so Lua re-mounts cleanly.
    bool weMounted = false;
    if (!Card_isMounted(1))
    {
      if (!Card_mount(1))
      {
        // No front card yet — leave the magic set; a later boot with a card in
        // will flush it. Fail-safe.
        return 0;
      }
      weMounted = true;
    }

    char path[32];
    snprintf(path, sizeof(path), "%s/crash.log", globalConfig.frontRoot);

    FIL f;
    FRESULT fr = f_open(&f, path, FA_OPEN_APPEND | FA_WRITE);
    if (fr != FR_OK)
    {
      if (weMounted)
      {
        Card_unmount(1);
      }
      return 0;
    }

    char line[320];

    // [stol:crashdiag-fix-flush-error-handling] Accumulate write success across
    // the whole block. panicPut() returns false on a short/failed f_write and
    // f_close is checked below; the panic magic is cleared ONLY if the entire
    // block landed. On any failure the magic survives so the existing next-boot
    // retry re-attempts (protecting the single copy on a full/failing card).
    bool ok = true;

    ok &= panicPut(&f,"---CRASH REPORT BEGIN\n");
    ok &= panicPut(&f,"Schema: 2\n");
    snprintf(line, sizeof(line), "Kind: %s\n", panicKindString(rec->faultType));
    ok &= panicPut(&f,line);
    snprintf(line, sizeof(line), "Time Since Boot: %0.3fs\n", (double)rec->wallclock);
    ok &= panicPut(&f,line);
    // [stol:crashdiag-fix-fwversion-capture-time] Print the CAPTURE-time version
    // recorded in the panic buffer, not the flushing binary's FIRMWARE_VERSION.
    if (rec->fwVersion[0])
    {
      snprintf(line, sizeof(line), "Firmware Version: %s\n", rec->fwVersion);
    }
    else
    {
      snprintf(line, sizeof(line), "Firmware Version: ?\n");
    }
    ok &= panicPut(&f,line);
    // TODO(crash-diag integration): boot/mount counts live in Lua Persist.meta
    // and are not reachable from this C-side capture, so they are reported as
    // unknown. Separate labels (not "Boot/Mount Count") per the canonical
    // contract docs/CRASH_REPORT_FORMAT.md so old readers still cope.
    ok &= panicPut(&f,"Boot Count: ?\n");
    ok &= panicPut(&f,"Mount Count: ?\n");
    if (rec->threadName[0])
    {
      snprintf(line, sizeof(line), "Thread: %s\n", rec->threadName);
    }
    else
    {
      const char *tt = "unknown";
      if (rec->threadType == BIOS_ThreadType_Task)
        tt = "task";
      else if (rec->threadType == BIOS_ThreadType_Swi)
        tt = "swi";
      else if (rec->threadType == BIOS_ThreadType_Hwi)
        tt = "hwi";
      else if (rec->threadType == BIOS_ThreadType_Main)
        tt = "main";
      snprintf(line, sizeof(line), "Thread: %s (handle=0x%x)\n", tt,
               (unsigned)rec->threadHandle);
    }
    ok &= panicPut(&f,line);

    ok &= panicPut(&f,"--- Registers ---\n");
    snprintf(line, sizeof(line), " pc=%08x lr=%08x sp=%08x psr=%08x\n",
             (unsigned)rec->pc, (unsigned)rec->lr, (unsigned)rec->sp,
             (unsigned)rec->psr);
    ok &= panicPut(&f,line);
    snprintf(line, sizeof(line), " dfsr=%08x ifsr=%08x dfar=%08x ifar=%08x\n",
             (unsigned)rec->dfsr, (unsigned)rec->ifsr, (unsigned)rec->dfar,
             (unsigned)rec->ifar);
    ok &= panicPut(&f,line);
    snprintf(line, sizeof(line),
             " r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x\n",
             (unsigned)rec->r[0], (unsigned)rec->r[1], (unsigned)rec->r[2],
             (unsigned)rec->r[3], (unsigned)rec->r[4], (unsigned)rec->r[5],
             (unsigned)rec->r[6]);
    ok &= panicPut(&f,line);
    snprintf(line, sizeof(line),
             " r7=%08x r8=%08x r9=%08x r10=%08x r11=%08x r12=%08x\n",
             (unsigned)rec->r[7], (unsigned)rec->r[8], (unsigned)rec->r[9],
             (unsigned)rec->r[10], (unsigned)rec->r[11], (unsigned)rec->r[12]);
    ok &= panicPut(&f,line);

    // Format matches od/glue/CrashDiag.cpp l_getModuleMap so the C (hardware) and
    // Lua (emu) reports render identically for tools/symbolize_crash.py.
    ok &= panicPut(&f,"--- Module Map ---\n");
    for (uint32_t i = 0; i < rec->moduleCount; i++)
    {
      PanicModuleEntry *m = &rec->modules[i];
      char textPart[64];
      char dataPart[64];
      if (m->textSize > 0)
      {
        snprintf(textPart, sizeof(textPart), "text=%08x..%08x",
                 (unsigned)m->textBase, (unsigned)(m->textBase + m->textSize));
      }
      else if (m->textBase != 0)
      {
        snprintf(textPart, sizeof(textPart), "text=%08x..?", (unsigned)m->textBase);
      }
      else
      {
        snprintf(textPart, sizeof(textPart), "text=0");
      }
      if (m->dataSize > 0)
      {
        snprintf(dataPart, sizeof(dataPart), "  data=%08x..%08x",
                 (unsigned)m->dataBase, (unsigned)(m->dataBase + m->dataSize));
      }
      else
      {
        dataPart[0] = '\0';
      }
      snprintf(line, sizeof(line), " %-24s %s%s\n", m->path, textPart, dataPart);
      ok &= panicPut(&f,line);
    }

    ok &= panicPut(&f,"--- Fault Resolution ---\n");
    {
      char res[128];
      panicResolve(rec, rec->pc, res, sizeof(res));
      snprintf(line, sizeof(line), " pc in %s\n", res);
      ok &= panicPut(&f,line);
      panicResolve(rec, rec->lr, res, sizeof(res));
      snprintf(line, sizeof(line), " lr in %s\n", res);
      ok &= panicPut(&f,line);
    }

    // [stol:crashdiag-hang-spin-pc] Hang sub-case, so the reader knows how to
    // read the Stack Window: "running (spin)" => sp is the LIVE interrupted SP
    // and the window is the live call chain; "blocked" => sp is the saved block
    // site. Emitted for hang captures only.
    if (rec->faultType == PANIC_FAULT_HANG)
    {
      snprintf(line, sizeof(line), "Hang State: %s\n",
               rec->hangRunning ? "running (spin)" : "blocked");
      ok &= panicPut(&f, line);
    }

    // [stol:infra-crash-diag-hang-watchdog] Stack Window (hang captures only;
    // stackWindowSp is zero for the trap path). Address-prefixed hex, 4 words
    // (16 bytes) per line, ascending address == innermost-frame-first so the
    // offline symbolizer prints a candidate backtrace in call order. Words are
    // little-endian reads of the raw copied stack (memcpy avoids any alignment
    // trap). Format contract: docs/CRASH_REPORT_FORMAT.md.
    if (rec->stackWindowSp != 0 && rec->stackWindowLen > 0)
    {
      ok &= panicPut(&f, "--- Stack Window ---\n");
      snprintf(line, sizeof(line), " sp=%08x bytes=%u\n",
               (unsigned)rec->stackWindowSp, (unsigned)rec->stackWindowLen);
      ok &= panicPut(&f, line);
      for (uint32_t off = 0; off < rec->stackWindowLen; off += 16)
      {
        char words[64];
        int wp = 0;
        for (uint32_t j = 0; j < 16 && off + j < rec->stackWindowLen; j += 4)
        {
          uint32_t w = 0;
          uint32_t avail = rec->stackWindowLen - (off + j);
          memcpy(&w, &rec->stackWindow[off + j], avail < 4 ? avail : 4);
          wp += snprintf(words + wp, sizeof(words) - wp, " %08x", (unsigned)w);
        }
        snprintf(line, sizeof(line), " %08x:%s\n",
                 (unsigned)(rec->stackWindowSp + off), words);
        ok &= panicPut(&f, line);
      }
    }

    ok &= panicPut(&f,"--- Flight Recorder ---\n");
    if (rec->frCount == 0)
    {
      ok &= panicPut(&f," (empty)\n");
    }
    else
    {
      for (uint32_t i = 0; i < rec->frCount; i++)
      {
        snprintf(line, sizeof(line), " %8.3fs  %s\n", (double)rec->fr[i].t,
                 rec->fr[i].label);
        ok &= panicPut(&f,line);
      }
    }

    // Recent Log ring lives in the Lua LogHistory and is not reachable from this
    // C-side capture. Keep the pre-schema "Recent Log Messages:" label so old
    // readers cope (docs/CRASH_REPORT_FORMAT.md).
    ok &= panicPut(&f,"--- Recent Log ---\n");
    ok &= panicPut(&f,"Recent Log Messages:\n");
    ok &= panicPut(&f," (not captured C-side; see flight recorder above)\n");

    ok &= panicPut(&f,"---CRASH REPORT END\n");

    // f_close flushes FatFS's dirty buffers; a failure here can mean the tail of
    // the block never reached the card, so fold it into the success flag too.
    if (f_close(&f) != FR_OK)
    {
      ok = false;
    }

    // [stol:crashdiag-fix-flush-error-handling] Only advertise + retire the
    // record if the WHOLE block wrote cleanly. On a partial/failed write we
    // leave the magic set (skip PanicBuffer_clear) so a later boot retries,
    // and skip the pending marker so the user is not pointed at a truncated
    // report this boot (the next successful flush drops it).
    if (ok)
    {
      // Drop the pending-crash marker (xroot/CrashReport.lua) so the sibling's
      // on-boot notice ("A crash was captured...") fires. One summary line.
      char pending[32];
      snprintf(pending, sizeof(pending), "%s/crash.pending", globalConfig.frontRoot);
      FIL pf;
      if (f_open(&pf, pending, FA_CREATE_ALWAYS | FA_WRITE) == FR_OK)
      {
        char sum[96];
        const char *who = rec->threadName[0] ? rec->threadName : "?";
        snprintf(sum, sizeof(sum), "%s in %s (pc=%08x)\n",
                 panicKindString(rec->faultType), who, (unsigned)rec->pc);
        UINT bw = 0;
        f_write(&pf, sum, (UINT)strlen(sum), &bw);
        f_close(&pf);
      }
    }

    if (weMounted)
    {
      Card_unmount(1);
    }

    if (!ok)
    {
      // Record preserved for the next boot's retry. No card scrub, no clear.
      logInfo("PanicBuffer: crash.log write failed (card full/error?); "
              "keeping record for retry");
      return 0;
    }

    PanicBuffer_clear();

    logInfo("PanicBuffer: flushed captured crash report to %s", path);
    return 1;
  }

  // ---------------------------------------------------------------------------
  // Hardware fault injection (section 6 test procedure)
  // ---------------------------------------------------------------------------

  void Crash_testTrap(int kind)
  {
    // Make sure a single call yields a persisted report.
    Crash_arm(true);
    Crash_setAutoReboot(true);

    logInfo("Crash_testTrap: injecting deliberate fault (kind=%d)...", kind);

    if (kind == 1)
    {
      // ARM permanently-undefined instruction (ARMv7) -> undef trap.
      __asm__ __volatile__(".word 0xe7f000f0");
    }
    else
    {
      // Write to an unmapped address -> data abort. 0xF0000000 is outside the
      // MMU-mapped peripheral window (0x44000000-0x57000000) and DDR
      // (0x80000000+), so it translation-faults.
      volatile uint32_t *p = (volatile uint32_t *)0xF0000000u;
      *p = 0xDEADBEEFu;
    }

    // Should never get here.
    while (1)
    {
    }
  }

#ifdef BUILDOPT_CRASH_TEST
  // [stol:infra-crash-diag-hang-watchdog] Livelock flag for the 'h' trigger. Set
  // here at boot, read by the audio task (arch/am335x/hal/audio.c), which spins
  // forever on its next frame so the Clock monitor catches a deliberate hang.
  volatile bool g_crashTestHang = false;
#endif

  void PanicBuffer_checkTestTrigger(void)
  {
    bool weMounted = false;
    if (!Card_isMounted(1))
    {
      if (!Card_mount(1))
      {
        return; // no front card -> nothing to do
      }
      weMounted = true;
    }

    char path[32];
    snprintf(path, sizeof(path), "%s/CRASH_TEST", globalConfig.frontRoot);

    if (!pathExists(path))
    {
      if (weMounted)
      {
        Card_unmount(1);
      }
      return;
    }

    // Read the first byte to select the fault kind ('u' == undef, 'h' == hang).
    int kind = 0;
    {
      FIL tf;
      if (f_open(&tf, path, FA_READ) == FR_OK)
      {
        char c = 0;
        UINT br = 0;
        if (f_read(&tf, &c, 1, &br) == FR_OK && br == 1)
        {
          if (c == 'u' || c == 'U')
          {
            kind = 1; // undefined instruction
          }
          else if (c == 'h' || c == 'H')
          {
            kind = 2; // hang-watchdog livelock
          }
        }
        f_close(&tf);
      }
    }

    // One-shot: remove the trigger so the NEXT boot flushes the report and boots
    // normally instead of re-triggering.
    deleteFile(path);

    if (weMounted)
    {
      Card_unmount(1);
    }

#ifdef BUILDOPT_CRASH_TEST
    if (kind == 2)
    {
      // [stol:infra-crash-diag-hang-watchdog] Hang test: do NOT trap. Arm
      // diagnostics + auto-reboot + the hang monitor, raise the livelock flag,
      // and RETURN so boot continues to Audio_init/Audio_start. The audio task
      // then spins on its next frame and the Clock monitor snapshots + reboots.
      Crash_arm(true);
      Crash_setAutoReboot(true);
      g_crashTestHang = true;
      logInfo("Crash test: hang livelock armed; audio task will spin next frame.");
      return;
    }
#endif

    Crash_testTrap(kind); // does not return
  }

} // extern "C"
