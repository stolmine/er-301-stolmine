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

  // ---------------------------------------------------------------------------
  // Panic record layout (lives at __panic_buffer_start__)
  // ---------------------------------------------------------------------------

#define PANIC_MAGIC 0x53544C43u // 'STLC' — stolmine crash
#define PANIC_VERSION 2u        // matches the crash-report schema version
#define PANIC_MAX_MODULES 48
#define PANIC_MAX_FR_EVENTS 32
#define PANIC_FR_LABEL_LEN 48
#define PANIC_THREAD_NAME_LEN 16

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

    // Module map
    uint32_t moduleCount;
    PanicModuleEntry modules[PANIC_MAX_MODULES];

    // Flight recorder ring (chronological, oldest first)
    uint32_t frCount;
    PanicFrEvent fr[PANIC_MAX_FR_EVENTS];
  } PanicRecord;

  // ---------------------------------------------------------------------------
  // Arm / behavior state (plain globals — no constructors, zero-cost when off)
  // ---------------------------------------------------------------------------

  static bool g_autoReboot = true;
  static volatile int g_inHook = 0;

  void Crash_arm(bool on)
  {
    od::flightRecorder().arm(on);
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
    if (g_inHook)
    {
      return; // nested fault while capturing — bail, do not recurse
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

    // Module map — allocation-free reader over the dlopen registry.
    rec->moduleCount = (uint32_t)panicEnumerateModules(rec->modules, PANIC_MAX_MODULES);

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

    // DDR is cached: push the record out of D-cache to DRAM so it survives the
    // reset (a warm reset drops cache lines without writeback).
    Cache_wbInv((Ptr)__panic_buffer_start__, (SizeT)sizeof(PanicRecord), (Bits16)Cache_Type_ALL, (Bool)TRUE);

    // Warm-reboot so the DDR buffer survives (a cold power-cycle would lose it).
    // Gated so the classic behavior is preserved when auto-reboot is disabled.
    if (g_autoReboot)
    {
      reboot(); // WDT warm reset; returns, then fires a few ticks later
    }

    g_inHook = 0;
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
    case Exception_Type_Supervisor:
      return "swi";
    default:
      return "unknown";
    }
  }

  // Resolve a code address to "<module> + <offset>" using the captured map.
  // Kernel is not relocated on am335x, so a DDR-code address that matches no
  // package is reported as "kernel + <absolute addr>" (feed straight to addr2line
  // against kernel.elf). Anything else is "?".
  static void panicResolve(PanicRecord *rec, uint32_t addr, char *out, size_t n)
  {
    for (uint32_t i = 0; i < rec->moduleCount; i++)
    {
      PanicModuleEntry *m = &rec->modules[i];
      if (m->textSize > 0 && addr >= m->textBase &&
          addr < m->textBase + m->textSize)
      {
        snprintf(out, n, "%s + 0x%x", m->path,
                 (unsigned)(addr - (uint32_t)m->textBase));
        return;
      }
    }
    if (addr >= 0x80000000u && addr < 0xA0000000u)
    {
      snprintf(out, n, "kernel + 0x%x", (unsigned)addr);
      return;
    }
    snprintf(out, n, "?");
  }

  // Append a NUL-terminated string to the open file.
  static void panicPut(FIL *f, const char *s)
  {
    UINT bw = 0;
    f_write(f, s, (UINT)strlen(s), &bw);
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

    panicPut(&f, "---CRASH REPORT BEGIN\n");
    panicPut(&f, "Schema: 2\n");
    snprintf(line, sizeof(line), "Kind: %s\n", panicKindString(rec->faultType));
    panicPut(&f, line);
    snprintf(line, sizeof(line), "Time Since Boot: %0.3fs\n", (double)rec->wallclock);
    panicPut(&f, line);
#ifdef FIRMWARE_VERSION
    snprintf(line, sizeof(line), "Firmware Version: %s\n", FIRMWARE_VERSION);
#else
    snprintf(line, sizeof(line), "Firmware Version: ?\n");
#endif
    panicPut(&f, line);
    // TODO(crash-diag integration): boot/mount counts live in Lua Persist.meta
    // and are not reachable from this C-side capture, so they are reported as
    // unknown. Separate labels (not "Boot/Mount Count") per the canonical
    // contract docs/CRASH_REPORT_FORMAT.md so old readers still cope.
    panicPut(&f, "Boot Count: ?\n");
    panicPut(&f, "Mount Count: ?\n");
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
    panicPut(&f, line);

    panicPut(&f, "--- Registers ---\n");
    snprintf(line, sizeof(line), " pc=%08x lr=%08x sp=%08x psr=%08x\n",
             (unsigned)rec->pc, (unsigned)rec->lr, (unsigned)rec->sp,
             (unsigned)rec->psr);
    panicPut(&f, line);
    snprintf(line, sizeof(line), " dfsr=%08x ifsr=%08x dfar=%08x ifar=%08x\n",
             (unsigned)rec->dfsr, (unsigned)rec->ifsr, (unsigned)rec->dfar,
             (unsigned)rec->ifar);
    panicPut(&f, line);
    snprintf(line, sizeof(line),
             " r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x\n",
             (unsigned)rec->r[0], (unsigned)rec->r[1], (unsigned)rec->r[2],
             (unsigned)rec->r[3], (unsigned)rec->r[4], (unsigned)rec->r[5],
             (unsigned)rec->r[6]);
    panicPut(&f, line);
    snprintf(line, sizeof(line),
             " r7=%08x r8=%08x r9=%08x r10=%08x r11=%08x r12=%08x\n",
             (unsigned)rec->r[7], (unsigned)rec->r[8], (unsigned)rec->r[9],
             (unsigned)rec->r[10], (unsigned)rec->r[11], (unsigned)rec->r[12]);
    panicPut(&f, line);

    // Format matches od/glue/CrashDiag.cpp l_getModuleMap so the C (hardware) and
    // Lua (emu) reports render identically for tools/symbolize_crash.py.
    panicPut(&f, "--- Module Map ---\n");
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
      panicPut(&f, line);
    }

    panicPut(&f, "--- Fault Resolution ---\n");
    {
      char res[128];
      panicResolve(rec, rec->pc, res, sizeof(res));
      snprintf(line, sizeof(line), " pc in %s\n", res);
      panicPut(&f, line);
      panicResolve(rec, rec->lr, res, sizeof(res));
      snprintf(line, sizeof(line), " lr in %s\n", res);
      panicPut(&f, line);
    }

    panicPut(&f, "--- Flight Recorder ---\n");
    if (rec->frCount == 0)
    {
      panicPut(&f, " (empty)\n");
    }
    else
    {
      for (uint32_t i = 0; i < rec->frCount; i++)
      {
        snprintf(line, sizeof(line), " %8.3fs  %s\n", (double)rec->fr[i].t,
                 rec->fr[i].label);
        panicPut(&f, line);
      }
    }

    // Recent Log ring lives in the Lua LogHistory and is not reachable from this
    // C-side capture. Keep the pre-schema "Recent Log Messages:" label so old
    // readers cope (docs/CRASH_REPORT_FORMAT.md).
    panicPut(&f, "--- Recent Log ---\n");
    panicPut(&f, "Recent Log Messages:\n");
    panicPut(&f, " (not captured C-side; see flight recorder above)\n");

    panicPut(&f, "---CRASH REPORT END\n");

    f_close(&f);

    // Drop the pending-crash marker (xroot/CrashReport.lua) so the sibling's
    // on-boot notice ("A crash was captured...") fires. One summary line.
    {
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

    // Read the first byte to select the fault kind ('u' == undef).
    int kind = 0;
    {
      FIL tf;
      if (f_open(&tf, path, FA_READ) == FR_OK)
      {
        char c = 0;
        UINT br = 0;
        if (f_read(&tf, &c, 1, &br) == FR_OK && br == 1 && (c == 'u' || c == 'U'))
        {
          kind = 1;
        }
        f_close(&tf);
      }
    }

    // One-shot: remove the trigger so the NEXT boot flushes the report and boots
    // normally instead of re-trapping.
    deleteFile(path);

    if (weMounted)
    {
      Card_unmount(1);
    }

    Crash_testTrap(kind); // does not return
  }

} // extern "C"
