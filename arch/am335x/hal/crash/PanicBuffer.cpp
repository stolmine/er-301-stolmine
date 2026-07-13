// [stol:infra-crash-diag-panic-buffer][stol:infra-crash-diag-exc-hook]
//
// HARDWARE crash capture for am335x. See hal/crash.h for the overview.
//
// This half CANNOT be exercised in the emulator (the traps are hardware-only),
// so it is written to a static-analysis + on-hardware-test discipline; the
// hardware test procedure is planning/crash-diagnostics-plan.md section 6.

// [stol:crashdiag-stack-highwater] Opt into the SYS/BIOS Task_Object internal
// layout so the fault-safe stack scan can read stack base + stackSize directly
// off a Task_Handle, without Task_stat's internal Task_disable/restore (which
// may be unsafe from an abort context). This is the standard xdc internal-access
// opt-in and only reveals the state structs; it MUST precede any (even
// transitive) include of ti/sysbios/knl/Task.h, so it sits above every #include.
#define ti_sysbios_knl_Task__internalaccess

// [stol:crashdiag-object-guard-event] Same internal-access opt-in for the Event
// module, so the audio-Event pend-queue guard can locate the Event's pendQ
// (Queue_Object) header directly off an Event_Handle and validate its
// doubly-linked-sentinel invariant. Reveals only the state struct; must precede
// any (even transitive) include of ti/sysbios/knl/Event.h, so it sits with the
// Task opt-in above every #include.
#define ti_sysbios_knl_Event__internalaccess

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
// [stol:crashdiag-object-guard-event] Event + Queue internals for the audio-Event
// pend-queue guard (pendQ header lookup + Queue_Elem next/prev fields).
#include <ti/sysbios/knl/Event.h>
#include <ti/sysbios/knl/Queue.h>
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
  //   v6: added per-task + ISR stack high-water/canary (stacks[]/isrStack/
  //       stackCount/anyStackBlown). [stol:crashdiag-stack-highwater]
  //   v7: added audio-Event pend-queue guard breach detail (guardAddr/guardNext/
  //       guardPrev/guardReason). [stol:crashdiag-object-guard-event]
  //   v8: added heap pressure + last-alloc-fail (heapCeiling/heapArenaHighWater/
  //       heapAllocCount + heapLastFailSize/heapLastFailPc/heapLastFailArena/
  //       heapFailCount). [stol:crashdiag-heap-stats]
#define PANIC_VERSION 8u
#define PANIC_MAX_MODULES 48
#define PANIC_MAX_FR_EVENTS 32
#define PANIC_FR_LABEL_LEN 48
#define PANIC_THREAD_NAME_LEN 16
#define PANIC_FW_VERSION_LEN 32

  // [stol:crashdiag-stack-highwater] Max task stacks reported per capture. Bounds
  // the Task_Object_first/next walk (fault-safe: a fixed iteration cap even if the
  // object list is mid-mutation) and the PanicRecord footprint.
#define PANIC_MAX_TASKS 16
#define PANIC_STACK_NAME_LEN 16

  // [stol:crashdiag-stack-highwater] SYS/BIOS pre-fills task/ISR stacks with the
  // BYTE 0xbe (ti/sysbios/family/arm/TaskSupport.c:106-111, gated by
  // Task.initStackFlag), so an untouched 32-bit stack word reads 0xBEBEBEBE. The
  // canary is the word at the stack BASE (the deepest a full-descending stack can
  // reach); high-water is the first non-fill word scanning UP from base.
#define PANIC_STACK_FILL 0xBEBEBEBEu

  // [stol:infra-crash-diag-hang-watchdog] Sentinel faultType for a hang capture.
  // The trap path stores an Exception_Type (small values: 0x11 supervisor, 0x17
  // prefetch, 0x18 data, 0x1b undef); this ASCII 'HANG' sentinel cannot collide,
  // so panicKindString maps it to "hang-watchdog" without disturbing the enum.
#define PANIC_FAULT_HANG 0x484E4721u // 'HNG!'

  // [stol:crashdiag-object-guard-event] Sentinel faultType for an audio-Event
  // pend-queue guard breach (not an Exception_Type; same non-colliding ASCII
  // trick as PANIC_FAULT_HANG). panicKindString maps it to "event-guard-breach".
  // Detected when the audio ISR (or the hang tick) finds the Event's pendQ
  // doubly-linked sentinel broken BEFORE Event_post would walk it and trap.
#define PANIC_FAULT_GUARD 0x47524421u // 'GRD!'

  // [stol:crashdiag-object-guard-event] Which pendQ invariant failed (bitmask,
  // reported in the --- Event Guard --- section). NEXT/PREV_BADPTR = the header
  // link is not a mapped, 4-aligned DDR address (the Anamnesis signature: a
  // near-null clobbered next); NEXT/PREV_LINK = the link is mapped but the
  // doubly-linked back-pointer no longer points at the header (a torn chain).
#define PANIC_GUARD_REASON_NEXT_BADPTR 0x1u
#define PANIC_GUARD_REASON_PREV_BADPTR 0x2u
#define PANIC_GUARD_REASON_NEXT_LINK 0x4u
#define PANIC_GUARD_REASON_PREV_LINK 0x8u

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

  // [stol:crashdiag-stack-highwater] One task's (or the ISR's) stack accounting.
  // base = lowest address (full-descending stacks grow DOWN toward it); size in
  // bytes; used = high-water bytes = (base+size) - deepest-non-fill-word; canaryOk
  // = the word at base is still the 0xbe fill (nothing overflowed to/past base).
  typedef struct
  {
    char name[PANIC_STACK_NAME_LEN];
    uint32_t base;
    uint32_t size;
    uint32_t used;
    uint8_t canaryOk;
  } PanicStackEntry;

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

    // [stol:crashdiag-stack-highwater] Per-task + ISR stack high-water / canary.
    // Filled by panicEnumerateStacks() from BOTH the trap hook and the hang
    // capture. stackCount is how many task entries in stacks[] are valid;
    // isrStack is the Hwi/system stack; anyStackBlown is a 1-if-any summary (a
    // broken canary OR used >= 90% of size on any stack), which drives the
    // top-of-report BLOWN/NEAR-FULL banner.
    uint32_t stackCount;
    PanicStackEntry stacks[PANIC_MAX_TASKS];
    PanicStackEntry isrStack;
    uint8_t anyStackBlown;

    // [stol:crashdiag-object-guard-event] Audio-Event pend-queue guard breach
    // detail. Non-zero guardAddr => this record is a PANIC_FAULT_GUARD capture:
    // guardAddr is the watched pendQ header (Queue_Elem) address; guardNext /
    // guardPrev are the CORRUPTED next/prev links observed at the breach;
    // guardReason is the PANIC_GUARD_REASON_* bitmask. Zero for every other kind
    // (memset leaves them clear on the trap / hang paths).
    uint32_t guardAddr;
    uint32_t guardNext;
    uint32_t guardPrev;
    uint32_t guardReason;

    // [stol:crashdiag-heap-stats] Heap pressure (heap analog of the per-task
    // stacks above). Filled by panicFillHeap() from the plain globals the Heap_*
    // wrappers maintain (arch/am335x/hal/heap.c) -- a globals-only READ, so the
    // fault/Swi capture never calls sbrk / mallinfo / walks the free list.
    // Present in EVERY capture (trap / hang / guard). heapCeiling is the static
    // arena size; heapArenaHighWater the peak sbrk(0)-arena_start footprint;
    // heapAllocCount a running alloc count. The heapLastFail* group is the LAST
    // allocation failure (record-only; a NULL never reboots): size requested, the
    // caller pc (symbolizable), the arena high-water then, and a running fail
    // count. heapFailCount == 0 => no failure recorded (the fail line is omitted).
    uint32_t heapCeiling;
    uint32_t heapArenaHighWater;
    uint32_t heapAllocCount;
    uint32_t heapLastFailSize;
    uint32_t heapLastFailPc;
    uint32_t heapLastFailArena;
    uint32_t heapFailCount;
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

  // [stol:crashdiag-object-guard-event] Address of the audio Event's pendQ
  // (Queue_Elem) header, published once at Audio_init via PanicBuffer_setAudioEvent.
  // Zero => not registered yet (the guard check is then a no-op). Read on the
  // audio ISR hot path, so a plain word: written once, before any breach.
  static uint32_t g_audioEventPendQ = 0;

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
  // [stol:crashdiag-stack-highwater] Per-task + ISR stack high-water / canary.
  //
  // Shared by BOTH the trap hook (abort context) and the hang capture (Swi
  // context). Discipline: allocation-free, no scheduler lock, no Task_stat (its
  // internal Task_disable/restore may be unsafe from an abort context), every
  // read bounded by the stack's own size. All work is pure memory reads of the
  // stacks plus a fixed-cap walk of the task object list.
  // ---------------------------------------------------------------------------

  // A stack is "blown" (drives the banner + anyStackBlown) if its base canary is
  // broken OR it is at/over this percent of its size.
#define PANIC_STACK_NEARFULL_PCT 90u

  // [stol:crashdiag-stack-highwater] Fault-safe bounds for inspecting stacks from
  // an abort context. The whole 512 MB DDR window is MMU-mapped, so a read that
  // stays inside it CANNOT fault; a read OUTSIDE it (a clobbered stack pointer, a
  // garbage Task handle from a corrupted object list) would nested-fault the fault
  // handler and hang the device forever (the fault re-enters the hook, the
  // one-shot guard bails, control returns to the faulting load, it re-faults...).
  // The Anamnesis case proves the very structures we walk here can be corrupted,
  // so EVERY address + size is range-checked before a single dereference, and a
  // garbage size can never drive an unbounded scan.
#define PANIC_DDR_LO 0x80000000u
#define PANIC_DDR_HI 0xA0000000u
#define PANIC_MAX_STACK_BYTES (256u * 1024u)

  static inline bool panicAddrInDdr(uint32_t a)
  {
    return a >= PANIC_DDR_LO && a < PANIC_DDR_HI;
  }

  // A stack is safe to SCAN only if [base, base+size) lies wholly inside DDR and
  // size is plausible (>=4, <=256 KiB). Rejecting keeps the scan bounded AND every
  // read mapped.
  static inline bool panicStackRangeOk(uint32_t base, uint32_t size)
  {
    return size >= 4u && size <= PANIC_MAX_STACK_BYTES &&
           panicAddrInDdr(base) && base <= (PANIC_DDR_HI - size);
  }

  static bool panicStackIsBlown(const PanicStackEntry *e)
  {
    if (e->size == 0)
    {
      return false;
    }
    if (!e->canaryOk)
    {
      return true;
    }
    // used*100 stays well within uint32 for KB-sized stacks.
    return (e->used * 100u) >= (PANIC_STACK_NEARFULL_PCT * e->size);
  }

  // Fill one entry from a full-descending stack pre-filled with 0xbe. base is the
  // lowest address (the descending target), size the byte length. Scans word by
  // word UP from base for the first non-fill word: that address is the deepest
  // the stack ever reached, so used = (base+size) - it. canaryOk = the base word
  // is still the fill (an overflow writes down THROUGH base first). Bounded by
  // size/4 iterations; volatile reads so the scan is never optimized away.
  static void panicFillStackEntry(PanicStackEntry *e, const char *name,
                                  uint32_t base, uint32_t size)
  {
    memset(e, 0, sizeof(*e));
    // Only touch the name if the pointer itself is a mapped DDR address: a
    // corrupted Task env pointer must not fault us mid-capture.
    if (name && panicAddrInDdr((uint32_t)(uintptr_t)name))
    {
      strncpy(e->name, name, PANIC_STACK_NAME_LEN - 1);
    }
    e->base = base;
    e->size = size;
    if (!panicStackRangeOk(base, size))
    {
      // Corrupted / implausible bounds (base outside DDR, size 0 or absurd): mark
      // suspect (canary broken so panicStackIsBlown flags it -- a task whose stack
      // pointer got clobbered IS a corruption signal worth surfacing) but NEVER
      // scan, since an out-of-DDR read would nested-fault the abort handler and
      // hang. used=0 so a bogus size cannot trip the near-full path.
      e->used = 0;
      e->canaryOk = 0;
      return;
    }
    const volatile uint32_t *p = (const volatile uint32_t *)(uintptr_t)base;
    uint32_t words = size / 4u;
    e->canaryOk = (p[0] == PANIC_STACK_FILL) ? 1u : 0u;
    uint32_t i = 0;
    while (i < words && p[i] == PANIC_STACK_FILL)
    {
      i++;
    }
    // i == words => never touched (used 0). i == 0 => wrote down to base (blown).
    uint32_t highwater = base + i * 4u;
    e->used = (base + size) - highwater;
  }

  static void panicEnumerateStacks(PanicRecord *rec)
  {
    bool blown = false;
    uint32_t n = 0;

    // Read-only walk of the task object list. Task_Object_first/next traverse the
    // static + dynamic instance list without locking; the fixed PANIC_MAX_TASKS
    // cap keeps it bounded even if the list is mid-mutation in a fault context.
    for (Task_Handle t = Task_Object_first();
         t != (Task_Handle)0 && n < PANIC_MAX_TASKS;
         t = Task_Object_next(t))
    {
      // A corrupted object-list link can hand us a garbage handle; dereferencing
      // one outside DDR (t->stack / t->stackSize / Task_getEnv reads) would
      // nested-fault the abort handler. Stop the walk at the first bad handle.
      if (!panicAddrInDdr((uint32_t)(uintptr_t)t))
      {
        break;
      }
      const char *name = (const char *)Task_getEnv(t);
      // stack/stackSize are plain fields of the (fully-defined) Task_Object; this
      // is the same pair Task_stat copies, read here without the disable/restore.
      uint32_t base = (uint32_t)(uintptr_t)t->stack;
      uint32_t size = (uint32_t)t->stackSize;
      panicFillStackEntry(&rec->stacks[n], name, base, size);
      if (panicStackIsBlown(&rec->stacks[n]))
      {
        blown = true;
      }
      n++;
    }
    rec->stackCount = n;

    // ISR / system stack via the a8 Hwi. getStackInfo returns TRUE on overflow
    // (base byte != 0xbe) and fills peak/size/base; peak is 0 on overflow or if
    // the ISR stack was not pre-filled (hal.Hwi.initStackFlag). Map that onto the
    // same entry shape so the reader treats it uniformly.
    {
      Hwi_StackInfo info;
      memset(&info, 0, sizeof(info));
      Bool overflow = Hwi_getStackInfo(&info, (Bool)TRUE);
      PanicStackEntry *e = &rec->isrStack;
      memset(e, 0, sizeof(*e));
      strncpy(e->name, "isr", PANIC_STACK_NAME_LEN - 1);
      e->base = (uint32_t)(uintptr_t)info.hwiStackBase;
      e->size = (uint32_t)info.hwiStackSize;
      if (overflow)
      {
        e->used = (uint32_t)info.hwiStackSize;
        e->canaryOk = 0;
      }
      else
      {
        e->used = (uint32_t)info.hwiStackPeak;
        e->canaryOk = 1;
      }
      if (panicStackIsBlown(e))
      {
        blown = true;
      }
    }

    rec->anyStackBlown = blown ? 1u : 0u;
  }

  // ---------------------------------------------------------------------------
  // [stol:crashdiag-heap-stats] Heap pressure into the record — globals-only.
  //
  // The Heap_* wrappers (arch/am335x/hal/heap.c, task context) do ALL the work
  // (sbrk query, high-water, fail record) into plain volatile globals; here we
  // only COPY those globals into the record. That keeps the capture abort-safe:
  // no sbrk, no mallinfo, no free-list walk in the fault/Swi context (the free
  // list is exactly what a heap-exhaustion bug corrupts). Shared by all three
  // capture paths (trap / hang / guard). On the emu these symbols are undefined,
  // but this file is am335x-only so that is never linked there.
  // ---------------------------------------------------------------------------

  // Arena high-water is "near the ceiling" (drives the banner) at/above this pct.
#define PANIC_HEAP_NEARFULL_PCT 90u

  static void panicFillHeap(PanicRecord *rec)
  {
    rec->heapCeiling = g_heapCeiling;
    rec->heapArenaHighWater = g_heapArenaHighWater;
    rec->heapAllocCount = g_heapAllocCount;
    rec->heapLastFailSize = g_heapLastFailSize;
    rec->heapLastFailPc = g_heapLastFailPc;
    rec->heapLastFailArena = g_heapLastFailArena;
    rec->heapFailCount = g_heapFailCount;
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

    // [stol:crashdiag-stack-highwater] Per-task + ISR stack high-water / canary.
    // Same self-contained scan for both paths (see the routine's header); sets
    // rec->anyStackBlown for the flush banner.
    panicEnumerateStacks(rec);

    // [stol:crashdiag-heap-stats] Heap pressure + last-alloc-fail, copied from the
    // Heap_* wrapper globals (globals-only READ = abort-safe; no sbrk here).
    panicFillHeap(rec);

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

  // [stol:crashdiag-ui-heartbeat] Parameterized by target task so the UI hang can
  // snapshot the MAIN/app task, not just audio. The thin wrappers below preserve
  // the bench-validated audio path (PanicBuffer_captureHang == this, t=g_audioTask).
  static void panicCaptureHangTask(Task_Handle t)
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
    // [stol:crashdiag-ui-heartbeat] t is the target task (param), not hard-wired.
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

    // [stol:crashdiag-stack-highwater] Per-task + ISR stack high-water / canary.
    // Same self-contained scan for both paths (see the routine's header); sets
    // rec->anyStackBlown for the flush banner.
    panicEnumerateStacks(rec);

    // [stol:crashdiag-heap-stats] Heap pressure + last-alloc-fail, copied from the
    // Heap_* wrapper globals (globals-only READ = abort-safe; no sbrk here).
    panicFillHeap(rec);

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

  // [stol:crashdiag-ui-heartbeat] Audio-task shorthand (the bench-validated hang
  // path; behavior byte-identical to the pre-refactor PanicBuffer_captureHang).
  void PanicBuffer_captureHang(void)
  {
    panicCaptureHangTask((Task_Handle)g_audioTask);
  }

  // [stol:crashdiag-ui-heartbeat] Capture a hang on an ARBITRARY task (the UI hang
  // snapshots the main/app task, published by the monitor as g_uiTask).
  void PanicBuffer_captureHangTask(void *taskHandle)
  {
    panicCaptureHangTask((Task_Handle)taskHandle);
  }

  // ---------------------------------------------------------------------------
  // [stol:crashdiag-object-guard-event] Audio-Event pend-queue guard.
  //
  // The Anamnesis insert corrupts the audio Event's pend queue (a stray write
  // near 0x80538xxx clobbers pendQ->next to a near-null value); the NEXT audio
  // EDMA interrupt calls Event_post, walks the wrecked queue, dereferences the
  // near-null head, and traps in ti_sysbios_knl_Event_post (Event.c:285). That is
  // the DETECTION site, ~0.2s after the write. This guard moves detection to the
  // FIRST Event_post after the write: the audio ISR validates the pendQ sentinel
  // BEFORE posting; on a breach it seals a PANIC_FAULT_GUARD record (first-seen
  // wallclock + the corrupted links) and warm-reboots, shrinking the window to a
  // single audio frame and CONFIRMING the pendQ as the victim region.
  //
  // The pendQ is a SYS/BIOS Queue_Object == a doubly-linked-list sentinel
  // Queue_Elem { next, prev }. In every legitimate state (empty: next==prev==q;
  // one pended elem E: next==prev==E, E->prev==E->next==q) the invariant
  // "next and prev are mapped+aligned AND next->prev==q AND prev->next==q" holds.
  // The audio task manipulates pendQ only under Hwi_disable, and this check runs
  // in the EDMA Hwi BEFORE Event_post, so it always observes a settled queue --
  // no false positives from an in-flight post/pend.
  //
  // Zero cost when off: the caller (arch/am335x/hal/audio.c) gates the call on
  // g_hangArmed (one predicted branch when disarmed, same seam as the heartbeat).
  // ---------------------------------------------------------------------------

  void PanicBuffer_setAudioEvent(void *eventHandle)
  {
    g_audioEventPendQ = 0;
    if (!eventHandle || !panicAddrInDdr((uint32_t)(uintptr_t)eventHandle))
    {
      return;
    }
    // pendQ header = (Queue_Object*) at Event_Instance_State_pendQ__O into the
    // Event_Object; its first word is the sentinel Queue_Elem's `next`.
    Queue_Handle q = Event_Instance_State_pendQ((Event_Object *)eventHandle);
    uint32_t qa = (uint32_t)(uintptr_t)q;
    if (panicAddrInDdr(qa))
    {
      g_audioEventPendQ = qa;
    }
  }

  // Pure, allocation-free invariant test. Every dereference is guarded by a prior
  // DDR+aligned proof of the pointer, so a corrupted link can never fault us
  // (P0's rule: never read a clobbered pointer unchecked). Returns true on breach
  // and fills the observed links + the reason bitmask.
  static bool audioEventGuardBreached(uint32_t q, uint32_t *outNext,
                                      uint32_t *outPrev, uint32_t *outReason)
  {
    const volatile uint32_t *hdr = (const volatile uint32_t *)(uintptr_t)q;
    uint32_t next = hdr[0];
    uint32_t prev = hdr[1];
    *outNext = next;
    *outPrev = prev;

    uint32_t reason = 0;
    bool nextOk = panicAddrInDdr(next) && (next & 3u) == 0u;
    bool prevOk = panicAddrInDdr(prev) && (prev & 3u) == 0u;
    if (!nextOk)
    {
      reason |= PANIC_GUARD_REASON_NEXT_BADPTR;
    }
    if (!prevOk)
    {
      reason |= PANIC_GUARD_REASON_PREV_BADPTR;
    }
    // Sentinel back-pointer consistency, but ONLY through links we just proved
    // mapped + aligned. next->prev is word[1] of next; prev->next is word[0] of
    // prev; both must equal the header address q.
    if (nextOk)
    {
      uint32_t nextPrev = ((const volatile uint32_t *)(uintptr_t)next)[1];
      if (nextPrev != q)
      {
        reason |= PANIC_GUARD_REASON_NEXT_LINK;
      }
    }
    if (prevOk)
    {
      uint32_t prevNext = ((const volatile uint32_t *)(uintptr_t)prev)[0];
      if (prevNext != q)
      {
        reason |= PANIC_GUARD_REASON_PREV_LINK;
      }
    }
    *outReason = reason;
    return reason != 0;
  }

  // Seal a PANIC_FAULT_GUARD record. Reuses the trap/hang path's record / CRC /
  // module-map / stacks / flight-recorder / one-shot-latch / cache-clean /
  // warm-reboot machinery verbatim; only the fault identity + the Event-Guard
  // detail differ. Callable from the EDMA Hwi (audio ISR) or the Swi hang tick --
  // both strictly more permissive than the abort context the trap path already
  // survives. Bounded, allocation-free, one-shot.
  static void captureGuardBreach(uint32_t q, uint32_t next, uint32_t prev,
                                 uint32_t reason)
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
    rec->faultType = PANIC_FAULT_GUARD;

    // The corruptor is long gone (deferred detection), so pc stays 0; lr is the
    // detection site (the audio ISR that ran the check) as best-effort context.
    // The load-bearing signal is the Event-Guard detail below, not the registers.
    rec->lr = (uint32_t)(uintptr_t)__builtin_return_address(0);

    // Attribute to the audio task (the Event's owner) so Thread: reads "audio".
    Task_Handle t = (Task_Handle)g_audioTask;
    if (t && panicAddrInDdr((uint32_t)(uintptr_t)t))
    {
      rec->threadType = (uint32_t)BIOS_ThreadType_Task;
      rec->threadHandle = (uint32_t)(uintptr_t)t;
      const char *name = (const char *)Task_getEnv(t);
      if (name && panicAddrInDdr((uint32_t)(uintptr_t)name))
      {
        strncpy(rec->threadName, name, PANIC_THREAD_NAME_LEN - 1);
      }
    }

    rec->guardAddr = q;
    rec->guardNext = next;
    rec->guardPrev = prev;
    rec->guardReason = reason;

    rec->wallclock = wallclock(); // FIRST-SEEN time of the corruption.

#ifdef FIRMWARE_VERSION
    strncpy(rec->fwVersion, FIRMWARE_VERSION, sizeof(rec->fwVersion) - 1);
#endif

    rec->moduleCount = (uint32_t)panicEnumerateModules(rec->modules, PANIC_MAX_MODULES);
    if (rec->moduleCount > 0)
    {
      rec->modules[0].textBase = (uintptr_t)__kernel_text_start__;
      rec->modules[0].textSize =
          (uint32_t)((uintptr_t)__kernel_text_end__ - (uintptr_t)__kernel_text_start__);
    }

    // Per-task + ISR stacks: on the Anamnesis case one Task_Object is ALSO
    // clobbered, and panicEnumerateStacks surfaces it (fault-safe walk, P0), so
    // the guard report carries the same corruption fingerprint the trap did.
    panicEnumerateStacks(rec);

    // [stol:crashdiag-heap-stats] Heap pressure + last-alloc-fail (globals-only
    // READ). The confirmed Anamnesis root cause is heap exhaustion, so a guard
    // breach report should also show the arena at/near the ceiling.
    panicFillHeap(rec);

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

    rec->crc = panicCrc32((const uint8_t *)&rec->version, panicPayloadLen());
    rec->magic = PANIC_MAGIC;
    g_captured = true;

    Cache_wbInv((Ptr)__panic_buffer_start__, (SizeT)sizeof(PanicRecord), (Bits16)Cache_Type_ALL, (Bool)TRUE);

    if (g_autoReboot)
    {
      reboot(); // WDT warm reset; DDR keeps its charge so the buffer survives.
    }
  }

  void PanicBuffer_checkAudioEventGuard(void)
  {
    // Fast rejects (hot path): unregistered, disarmed, or already sealed.
    if (g_audioEventPendQ == 0 || g_captured)
    {
      return;
    }
    if (!od::flightRecorder().armed())
    {
      return;
    }
    uint32_t next = 0, prev = 0, reason = 0;
    if (audioEventGuardBreached(g_audioEventPendQ, &next, &prev, &reason))
    {
      captureGuardBreach(g_audioEventPendQ, next, prev, reason);
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
    // [stol:crashdiag-object-guard-event] Audio-Event pend-queue guard breach.
    case PANIC_FAULT_GUARD:
      return "event-guard-breach";
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

  // [stol:crashdiag-stack-highwater] Percent of a stack consumed at high-water.
  static unsigned panicStackPct(const PanicStackEntry *e)
  {
    return e->size ? (unsigned)((e->used * 100u) / e->size) : 0u;
  }

  // [stol:crashdiag-heap-stats] Percent of the heap ceiling the arena high-water
  // has reached (0 if the ceiling is unknown, e.g. no alloc happened while armed).
  static unsigned panicHeapPct(const PanicRecord *rec)
  {
    return rec->heapCeiling
               ? (unsigned)(((uint64_t)rec->heapArenaHighWater * 100u) /
                            rec->heapCeiling)
               : 0u;
  }

  // [stol:crashdiag-stack-highwater] Top-of-report banner(s): a broken canary is
  // an outright overflow (BLOWN), an intact-but->=90%-used stack is NEAR-FULL.
  // BLOWN entries lead so the prime suspect is unmissable. Iterates the task
  // stacks then the ISR entry (index == stackCount). Returns the accumulated
  // write success so the caller folds it into the flush's all-or-nothing flag.
  static bool panicEmitStackBanners(FIL *f, PanicRecord *rec)
  {
    bool ok = true;
    char line[96];
    for (uint32_t i = 0; i <= rec->stackCount; i++)
    {
      PanicStackEntry *e = (i < rec->stackCount) ? &rec->stacks[i] : &rec->isrStack;
      if (e->size && !e->canaryOk)
      {
        snprintf(line, sizeof(line), " *** STACK %s BLOWN ***\n", e->name);
        ok &= panicPut(f, line);
      }
    }
    for (uint32_t i = 0; i <= rec->stackCount; i++)
    {
      PanicStackEntry *e = (i < rec->stackCount) ? &rec->stacks[i] : &rec->isrStack;
      if (e->size && e->canaryOk &&
          (e->used * 100u) >= (PANIC_STACK_NEARFULL_PCT * e->size))
      {
        snprintf(line, sizeof(line), " *** STACK %s NEAR-FULL (%u%%) ***\n",
                 e->name, panicStackPct(e));
        ok &= panicPut(f, line);
      }
    }
    return ok;
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
    // [stol:crashdiag-stack-highwater] Prime-suspect banner near the TOP of the
    // block (right after Kind) so a blown / near-full stack is unmissable. The
    // full per-stack numbers follow in the --- Stacks --- section below.
    if (rec->anyStackBlown)
    {
      ok &= panicEmitStackBanners(&f, rec);
    }
    // [stol:crashdiag-object-guard-event] Prime-suspect banner for a guard breach
    // near the TOP (right after Kind), matching the blown-stack banner discipline
    // so the confirmed victim region is unmissable.
    if (rec->faultType == PANIC_FAULT_GUARD)
    {
      ok &= panicPut(&f, " *** EVENT GUARD BREACH (audio pendQ corrupted) ***\n");
    }
    // [stol:crashdiag-heap-stats] Prime-suspect banner near the TOP (right after
    // Kind) when the arena high-water is within PANIC_HEAP_NEARFULL_PCT of the
    // ceiling -- the confirmed Anamnesis footprint signal, unmissable at a glance.
    if (rec->heapCeiling &&
        (uint64_t)rec->heapArenaHighWater * 100u >=
            (uint64_t)PANIC_HEAP_NEARFULL_PCT * rec->heapCeiling)
    {
      snprintf(line, sizeof(line), " *** HEAP NEAR-CEILING (%u%%) ***\n",
               panicHeapPct(rec));
      ok &= panicPut(&f, line);
    }
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

    // [stol:crashdiag-stack-highwater] Per-task + ISR stack high-water / canary.
    // One line per task then the ISR/system stack. canary=BLOWN means the base
    // guard word was overwritten (an overflow wrote down through the stack base);
    // a high pct with canary=ok is a near-miss. Present for BOTH trap and hang
    // captures. Format contract: docs/CRASH_REPORT_FORMAT.md.
    ok &= panicPut(&f, "--- Stacks ---\n");
    for (uint32_t i = 0; i <= rec->stackCount; i++)
    {
      PanicStackEntry *e = (i < rec->stackCount) ? &rec->stacks[i] : &rec->isrStack;
      snprintf(line, sizeof(line),
               " %-15s base=%08x size=%u used=%u (%u%%) canary=%s\n",
               e->name, (unsigned)e->base, (unsigned)e->size, (unsigned)e->used,
               panicStackPct(e), e->canaryOk ? "ok" : "BLOWN");
      ok &= panicPut(&f, line);
    }

    // [stol:crashdiag-heap-stats] Heap pressure (heap analog of --- Stacks ---).
    // Present in EVERY capture: ceiling (static arena size), arena-highwater (peak
    // sbrk footprint) + its pct of the ceiling, and a running alloc count. When a
    // NULL allocation was recorded (heapFailCount > 0) a second line names the LAST
    // failure -- requested size + caller pc (symbolizable via the module map) +
    // count. All values are copied from the Heap_* wrapper globals at capture time
    // (globals-only, abort-safe). Format contract: docs/CRASH_REPORT_FORMAT.md.
    ok &= panicPut(&f, "--- Heap ---\n");
    snprintf(line, sizeof(line),
             " ceiling=%u arena-highwater=%u (%u%%) allocs=%u\n",
             (unsigned)rec->heapCeiling, (unsigned)rec->heapArenaHighWater,
             panicHeapPct(rec), (unsigned)rec->heapAllocCount);
    ok &= panicPut(&f, line);
    if (rec->heapFailCount > 0)
    {
      snprintf(line, sizeof(line),
               " last-alloc-fail: size=%u pc=%08x (count=%u)\n",
               (unsigned)rec->heapLastFailSize, (unsigned)rec->heapLastFailPc,
               (unsigned)rec->heapFailCount);
      ok &= panicPut(&f, line);
    }

    // [stol:crashdiag-object-guard-event] Event Guard detail (guard breach only).
    // pendQ is the watched Queue_Elem header; next/prev are the CORRUPTED links
    // caught before Event_post would walk them; reason decodes which invariant
    // broke. This is the load-bearing signal for a deferred-corruption capture
    // (the registers are best-effort: pc=0, lr=the ISR detection site). Format
    // contract: docs/CRASH_REPORT_FORMAT.md.
    if (rec->faultType == PANIC_FAULT_GUARD)
    {
      ok &= panicPut(&f, "--- Event Guard ---\n");
      snprintf(line, sizeof(line),
               " pendQ=%08x next=%08x prev=%08x reason=%02x\n",
               (unsigned)rec->guardAddr, (unsigned)rec->guardNext,
               (unsigned)rec->guardPrev, (unsigned)rec->guardReason);
      ok &= panicPut(&f, line);
      // Human-readable decode of the reason bitmask (one token per failed rule).
      char why[96];
      int wp = 0;
      wp += snprintf(why + wp, sizeof(why) - wp, " reason:");
      if (rec->guardReason & PANIC_GUARD_REASON_NEXT_BADPTR)
        wp += snprintf(why + wp, sizeof(why) - wp, " next-badptr");
      if (rec->guardReason & PANIC_GUARD_REASON_PREV_BADPTR)
        wp += snprintf(why + wp, sizeof(why) - wp, " prev-badptr");
      if (rec->guardReason & PANIC_GUARD_REASON_NEXT_LINK)
        wp += snprintf(why + wp, sizeof(why) - wp, " next-link");
      if (rec->guardReason & PANIC_GUARD_REASON_PREV_LINK)
        wp += snprintf(why + wp, sizeof(why) - wp, " prev-link");
      snprintf(why + wp, sizeof(why) - wp, "\n");
      ok &= panicPut(&f, why);
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
  // [stol:crashdiag-ui-heartbeat] g_uiCrashTest (the 'U' livelock flag) is DEFINED
  // in HangWatchdog.cpp; checkTestTrigger below only sets it (declared in crash.h).
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
          if (c == 'u')
          {
            kind = 1; // undefined instruction
          }
          else if (c == 'h' || c == 'H')
          {
            kind = 2; // hang-watchdog livelock (audio)
          }
          else if (c == 'U') // [stol:crashdiag-ui-heartbeat]
          {
            kind = 3; // UI/main-thread hang livelock
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
    if (kind == 3)
    {
      // [stol:crashdiag-ui-heartbeat] UI hang test: arm the facility AND the
      // separate UI-hang opt-in + auto-reboot, raise the UI livelock flag, and
      // RETURN so boot continues. The main task spins in Crash_uiHeartbeat on its
      // next busy edge and the monitor's UI heartbeat check snapshots + reboots.
      Crash_arm(true);
      Crash_uiHangArm(true);
      Crash_setAutoReboot(true);
      g_uiCrashTest = true;
      logInfo("Crash test: UI hang livelock armed; main task will spin.");
      return;
    }
#endif

    Crash_testTrap(kind); // does not return
  }

} // extern "C"
