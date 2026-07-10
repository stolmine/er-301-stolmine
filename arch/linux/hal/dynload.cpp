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

    // [stol:infra-crash-diag-module-map] The symbolication base must be the LOAD
    // BIAS (dlpi_addr), NOT dlpi_addr+p_vaddr. The host symbolizer computes
    //     offset = capturedAddr - textBase
    // and feeds that to addr2line, which wants the ELF link-time vaddr, i.e.
    //     capturedAddr - dlpi_addr  ==  p_vaddr + (offset within segment).
    // So we report textBase = dlpi_addr. To keep the module map's [lo..hi)
    // containment check covering the real runtime PCs (which live at
    // dlpi_addr + p_vaddr ..), the emitted text extent runs to the END of the
    // exec segment measured from the bias, i.e. textSize = p_vaddr + p_memsz.
    // Previously textBase = dlpi_addr + p_vaddr dropped p_vaddr from every
    // offset, shifting all emu file:line under separate-code linking.
    const uintptr_t loadBias = (uintptr_t)info->dlpi_addr;
    bool haveText = false;
    bool haveData = false;
    uintptr_t textEnd = 0; // max (p_vaddr + p_memsz) over exec segments
    uintptr_t dataVaddr = 0; // lowest writable p_vaddr
    size_t dataMemsz = 0;

    for (int i = 0; i < info->dlpi_phnum; i++)
    {
      const ElfW(Phdr) &ph = info->dlpi_phdr[i];
      if (ph.p_type != PT_LOAD)
      {
        continue;
      }
      const uintptr_t vaddr = (uintptr_t)ph.p_vaddr;
      const uintptr_t end = vaddr + (uintptr_t)ph.p_memsz;
      if (ph.p_flags & PF_X)
      {
        // Executable segment -> text. Base is the load bias (shared across all
        // segments); the extent must reach the end of the highest exec segment.
        if (!haveText || end > textEnd)
        {
          textEnd = end;
        }
        haveText = true;
      }
      else if (ph.p_flags & PF_W)
      {
        // Writable segment -> data (display only; not symbolized). Take the
        // first (lowest) one, reporting its real runtime start.
        if (!haveData || vaddr < dataVaddr)
        {
          dataVaddr = vaddr;
          dataMemsz = (size_t)ph.p_memsz;
        }
        haveData = true;
      }
    }

    if (haveText)
    {
      m.textBase = loadBias;         // == addr2line base (the load bias)
      m.textSize = (size_t)textEnd;  // range [loadBias .. loadBias+p_vaddr+memsz)
    }
    if (haveData)
    {
      m.dataBase = loadBias + dataVaddr; // real runtime data start
      m.dataSize = dataMemsz;
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
