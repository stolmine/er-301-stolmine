#ifndef _hal_modulemap_h
#define _hal_modulemap_h

// [stol:infra-crash-diag-module-map]
// Shared, arch-neutral enumerator for the crash-diagnostics module map.
//
// A crash report needs the runtime text/data base of every loaded code object so
// an offline symbolizer can turn a raw PC/LR into "package.so + offset" and then
// file:line (see docs/CRASH_REPORT_FORMAT.md, tools/symbolize_crash.py).
//
// The two firmware arches load packages by completely different paths:
//   - am335x: the custom dlopen registry (arch/am335x/hal/dynload/dlfcn.cpp holds
//     std::map<std::string, od::ElfFile*> mLoaded); enumerated over that map.
//   - emu (linux): packages are ordinary .so files loaded by Lua's require via the
//     system dynamic linker; enumerated with dl_iterate_phdr (arch/linux/hal).
//
// Each arch provides od::enumerateModules(); the shared Lua glue
// (od/glue/CrashDiag.cpp) formats the result into the report's Module Map section.
// The kernel/main-program is always reported first with the label "kernel".

#ifdef __cplusplus

#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>

namespace od
{
  struct ModuleInfo
  {
    std::string path;    // "kernel" or the package .so path
    uintptr_t textBase;  // runtime base of the code segment (0 == not relocated)
    size_t textSize;     // bytes (0 == unknown)
    uintptr_t dataBase;  // runtime base of the data segment (0 == unknown)
    size_t dataSize;     // bytes (0 == unknown)
  };

  // Fills 'out' (cleared first) with the kernel entry followed by every loaded
  // package. Safe to call from normal context; the am335x implementation only
  // reads the dlopen map and touches no locks, so the sibling's exception hook
  // may also call it from an abort context.
  void enumerateModules(std::vector<ModuleInfo> &out);
}

#endif // __cplusplus
#endif // _hal_modulemap_h
