#include <hal/log.h>
#include <hal/crash.h> // [stol:crashdiag-heap-stats] g_hangArmed gate + heap globals
#include <xdc/runtime/Memory.h>
#include <malloc.h> // [stol:crashdiag-heap-stats] malloc_usable_size()

// These symbols are defined in the linker script.
extern uintptr_t __unused_memory_start__;
extern uintptr_t __unused_memory_end__;
// [stol:crashdiag-heap-stats] The SYS/BIOS default heap (HeapMem heap0 =
// Memory_defaultHeapInstance) that malloc/Heap_* actually feed, and where the
// task stacks + the audio Event live (~0x805xxxxx). This is the arena the
// Anamnesis footprint bug exhausts, so it is the CORRECT ceiling (NOT
// __unused_memory, which is od::BigHeap). 20 MB (see linkcmd_er301.xdt kernel_heap).
extern uintptr_t __kernel_heap_start__;
extern uintptr_t __kernel_heap_end__;

// [stol:crashdiag-heap-stats] Heap-pressure instrument (heap analog of the P0
// stack high-water). These are the plain globals declared extern in hal/crash.h;
// the Heap_* wrappers maintain them, the panic capture only READS them (so the
// fault/Swi context never calls sbrk / mallinfo / walks the free list -- the P0
// abort-safety rule). Updates are gated on g_hangArmed (a plain bool load), so a
// disarmed build is unaffected at steady state.
volatile uint32_t g_heapCeiling = 0;
volatile uint32_t g_heapArenaHighWater = 0;
volatile uint32_t g_heapAllocCount = 0;
volatile uint32_t g_heapLastFailSize = 0;
volatile uint32_t g_heapLastFailPc = 0;
volatile uint32_t g_heapLastFailArena = 0;
volatile uint32_t g_heapFailCount = 0;

// Current in-use (live) newlib bytes. File-static: only the wrappers touch it.
// g_heapArenaHighWater tracks its PEAK -- the heap footprint high-water.
static uint32_t s_heapLive = 0;

// DEVIATION FROM THE P3 PLAN (required; see also hal/crash.h):
// the plan's g_heapArenaHighWater = sbrk(0) - __unused_memory_start__ is NOT
// implementable on this firmware:
//   (a) referencing sbrk/_sbrk pulls libgloss's sbrk.c, which needs an `end`
//       symbol this linker script does not define -- a hard LINK ERROR. This
//       newlib malloc is NOT sbrk-backed (SYS/BIOS supplies the arena), so there
//       is no break to query; and
//   (b) __unused_memory_start__..end is NOT this arena anyway -- that region is
//       owned by od::BigHeap (od/extras/BigHeap.cpp). The heap the Heap_* wrappers
//       feed (BufferPool / SystemBuffer / AlignmentAllocator / the Lua
//       interpreter) is the newlib heap in low DDR, which is exactly where the
//       Anamnesis footprint bug lands (~0x80538xxx).
// So the arena high-water is measured DIRECTLY as the PEAK live (in-use) bytes of
// the malloc heap, accounted in the wrappers via malloc_usable_size(). This is a
// linkable, cheap (one usable-size call + a couple of adds), footprint proxy that
// only ever falls when memory is freed. It is computed ONLY here (task context),
// NEVER in the capture (which reads plain globals only) -- so the plan's
// abort-safety rule is honored. g_heapCeiling is the kernel_heap size (20 MB, the
// SYS/BIOS default heap that malloc actually feeds and that the corruption lands
// in), so arena-highwater/ceiling is a SAME-HEAP pct -- when it nears 100% the heap
// is exhausted, which is the Anamnesis footprint failure. The Tier-2 last-alloc-fail
// (a NULL return) is the unambiguous confirmation.
extern size_t malloc_usable_size(void *ptr);

// Fold a signed delta into the live-byte counter, refresh the ceiling + the
// high-water. Clamped at 0 so an arm toggle mid-run cannot drive it negative.
static inline void heapAddLive(int32_t delta)
{
  if (g_heapCeiling == 0)
  {
    // Static ceiling = the kernel_heap size (the SYS/BIOS default heap malloc feeds
    // + where the corruption lands), so arena-highwater/ceiling is a same-heap pct.
    g_heapCeiling = (uint32_t)((uintptr_t)&__kernel_heap_end__ -
                               (uintptr_t)&__kernel_heap_start__);
  }
  int64_t v = (int64_t)s_heapLive + delta;
  s_heapLive = (v < 0) ? 0u : (uint32_t)v;
  if (s_heapLive > g_heapArenaHighWater)
  {
    g_heapArenaHighWater = s_heapLive;
  }
}

// Record a SUCCESSFUL allocation of p + bump the alloc count. Caller has already
// checked g_hangArmed, so this is off the disarmed path.
static inline void heapNoteAlloc(void *p)
{
  heapAddLive((int32_t)malloc_usable_size(p));
  g_heapAllocCount++;
}

// Record an allocation FAILURE (underlying malloc/memalign/calloc/realloc
// returned NULL). REFINEMENT: record-only -- do NOT force a warm reboot, so a
// benign NULL the caller handles never reboots the device. The next captured
// report (the downstream guard breach or trap) names the failing allocation
// (size + caller pc, symbolizable into libanamnesis.so). pc is the wrapper's own
// __builtin_return_address(0), captured in the wrapper and passed in so inlining
// this helper cannot shift the frame.
static inline void heapNoteFail(size_t size, void *pc)
{
  g_heapLastFailSize = (uint32_t)size;
  g_heapLastFailPc = (uint32_t)(uintptr_t)pc;
  g_heapLastFailArena = g_heapArenaHighWater;
  g_heapFailCount++;
}

uintptr_t Heap_getUnusedMemoryStart()
{
  return (uintptr_t)&__unused_memory_start__;
}

uint32_t Heap_getUnusedMemorySize()
{
  uintptr_t heapStart = (uintptr_t)&__unused_memory_start__;
  uintptr_t heapEnd = (uintptr_t)&__unused_memory_end__;
  uint32_t heapSize = heapEnd - heapStart;
  return heapSize;
}

void Heap_print(void)
{
  Memory_Stats stats;
  Memory_getStats(Memory_defaultHeapInstance, &stats);
  logInfo("Heap_print: using %dMB of %dMB largest=%dMB",
          (stats.totalSize - stats.totalFreeSize) / (1024 * 1024),
          stats.totalSize / (1024 * 1024),
          stats.largestFreeSize / (1024 * 1024));
}

int Heap_getSize(int units)
{
  Memory_Stats stats;
  Memory_getStats(Memory_defaultHeapInstance, &stats);
  return (int)(stats.totalSize / units);
}

int Heap_getFreeSize(int units)
{
  Memory_Stats stats;
  Memory_getStats(Memory_defaultHeapInstance, &stats);
  return (int)(stats.totalFreeSize / units);
}

void Heap_init()
{
}

// [stol:crashdiag-heap-stats] Each wrapper notes a successful alloc (live-byte
// high-water + count) or records the last failure, gated on g_hangArmed (one
// predicted branch when disarmed). A zero effective request that returns NULL is
// NOT a failure (malloc(0)/realloc(ptr,0) may legitimately return NULL), so the
// fail path is taken only for a nonzero request. Frees + reallocs adjust the live
// counter so the high-water tracks PEAK footprint, not cumulative churn.
void *Heap_memalign(size_t align, size_t size)
{
  void *p = memalign(align, size);
  if (g_hangArmed)
  {
    if (p)
      heapNoteAlloc(p);
    else if (size)
      heapNoteFail(size, __builtin_return_address(0));
  }
  return p;
}

void *Heap_malloc(size_t size)
{
  void *p = malloc(size);
  if (g_hangArmed)
  {
    if (p)
      heapNoteAlloc(p);
    else if (size)
      heapNoteFail(size, __builtin_return_address(0));
  }
  return p;
}

void *Heap_calloc(size_t nmemb, size_t size)
{
  void *p = calloc(nmemb, size);
  if (g_hangArmed)
  {
    if (p)
      heapNoteAlloc(p);
    else if (nmemb && size)
      heapNoteFail(nmemb * size, __builtin_return_address(0));
  }
  return p;
}

void *Heap_realloc(void *ptr, size_t size)
{
  // Snapshot the old usable size BEFORE realloc (it may free/move ptr). Only when
  // armed, so the disarmed path is a plain realloc.
  size_t oldsz = (g_hangArmed && ptr) ? malloc_usable_size(ptr) : 0;
  void *p = realloc(ptr, size);
  if (g_hangArmed)
  {
    if (p)
    {
      // Net change: new usable size minus the old block we replaced. count++.
      heapAddLive((int32_t)malloc_usable_size(p) - (int32_t)oldsz);
      g_heapAllocCount++;
    }
    else if (size)
    {
      heapNoteFail(size, __builtin_return_address(0));
    }
    else
    {
      // realloc(ptr, 0): the block was freed and NULL returned -- drop its bytes.
      heapAddLive(-(int32_t)oldsz);
    }
  }
  return p;
}

void Heap_free(void *ptr)
{
  // Drop the freed block's bytes from the live counter (read usable size before
  // free). Gated on g_hangArmed so a disarmed build is a plain free.
  if (g_hangArmed && ptr)
  {
    heapAddLive(-(int32_t)malloc_usable_size(ptr));
  }
  free(ptr);
}