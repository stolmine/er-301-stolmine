// [stol:infra-crash-diag-module-map]
// Emulator (linux) implementation of the crash-diagnostics module enumerator.
//
// Unlike the am335x firmware, the emu loads packages as ordinary shared objects
// via Lua's require -> the system dynamic linker, so there is no dlopen registry
// to walk. Instead we enumerate every loaded ELF object with dl_iterate_phdr
// (glibc), which yields the main program ("kernel") plus every .so. For each we
// derive the runtime text/data base+size from the program headers so the module
// map renders with real, non-empty data in the emu -- the thing the headless
// harness verifies (kernel + at least one package present).

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <hal/modulemap.h>

#include <link.h>
#include <string.h>

namespace
{
  struct Accumulator
  {
    std::vector<od::ModuleInfo> *out;
  };

  int callback(struct dl_phdr_info *info, size_t /*size*/, void *data)
  {
    Accumulator *acc = (Accumulator *)data;

    od::ModuleInfo m;
    // The main program reports an empty name; label it "kernel" so the report
    // format is identical across arches.
    if (info->dlpi_name == nullptr || info->dlpi_name[0] == '\0')
    {
      m.path = "kernel";
    }
    else
    {
      m.path = info->dlpi_name;
    }
    m.textBase = 0;
    m.textSize = 0;
    m.dataBase = 0;
    m.dataSize = 0;

    for (int i = 0; i < info->dlpi_phnum; i++)
    {
      const ElfW(Phdr) &ph = info->dlpi_phdr[i];
      if (ph.p_type != PT_LOAD)
      {
        continue;
      }
      uintptr_t base = (uintptr_t)info->dlpi_addr + (uintptr_t)ph.p_vaddr;
      if (ph.p_flags & PF_X)
      {
        // Executable segment -> text. Take the first (lowest) one.
        if (m.textBase == 0 || base < m.textBase)
        {
          m.textBase = base;
          m.textSize = (size_t)ph.p_memsz;
        }
      }
      else if (ph.p_flags & PF_W)
      {
        // Writable segment -> data.
        if (m.dataBase == 0 || base < m.dataBase)
        {
          m.dataBase = base;
          m.dataSize = (size_t)ph.p_memsz;
        }
      }
    }

    acc->out->push_back(m);
    return 0;
  }
}

namespace od
{
  void enumerateModules(std::vector<ModuleInfo> &out)
  {
    out.clear();
    Accumulator acc;
    acc.out = &out;
    dl_iterate_phdr(callback, &acc);

    // dl_iterate_phdr lists the main program first already, but guarantee a
    // "kernel" entry exists even in the degenerate case.
    bool haveKernel = false;
    for (auto &m : out)
    {
      if (m.path == "kernel")
      {
        haveKernel = true;
        break;
      }
    }
    if (!haveKernel)
    {
      ModuleInfo kernel;
      kernel.path = "kernel";
      kernel.textBase = 0;
      kernel.textSize = 0;
      kernel.dataBase = 0;
      kernel.dataSize = 0;
      out.insert(out.begin(), kernel);
    }
  }
}
