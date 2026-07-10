#include "ElfFile.h"
#include "dlfcn.h"
#define BUILDOPT_VERBOSE
#define BUILDOPT_DEBUG_LEVEL 10
#include <hal/log.h>
#include <hal/modulemap.h>
#include <hal/crash.h>
#include <map>
#include <string>
#include <string.h>

struct Local
{
  std::string mLastError;
  std::map<std::string, od::ElfFile *> mLoaded;
};

static Local local;

int dlclose(void *__handle)
{
  od::ElfFile *elf = (od::ElfFile *)__handle;
  logDebug(1, "closing %s", elf->path().c_str());
  if (elf->refCount() == 1)
  {
    local.mLoaded.erase(elf->path());
  }
  elf->release();
  return 0;
}

const char *dlerror(void)
{
  if (local.mLastError.empty())
  {
    return "No error.";
  }
  // Note: returning c_str() from a persistent string, cleared on next call
  return local.mLastError.c_str();
}

void *dlopen(const char *__path, int __mode)
{
  local.mLastError.clear();
  logDebug(1, "opening %s", __path);
  if (__mode != (RTLD_NOW | RTLD_LOCAL))
  {
    local.mLastError = "dlopen: Mode must be RTLD_NOW | RTLD_LOCAL.";
    return NULL;
  }
  auto i = local.mLoaded.find(__path);
  if (i != local.mLoaded.end())
  {
    // already loaded
    od::ElfFile *elf = i->second;
    logDebug(1, "already loaded %s", elf->path().c_str());
    elf->attach();
    return elf;
  }
  od::ElfFile *elf = new od::ElfFile();
  if (!elf->load(__path))
  {
    local.mLastError = elf->lastError();
    if (local.mLastError.empty())
    {
      local.mLastError = std::string("Failed to load ELF: ") + __path;
    }
    logError("dlopen failed: %s", local.mLastError.c_str());
    delete elf;
    return NULL;
  }
  elf->attach();
  local.mLoaded[__path] = elf;
  return elf;
}

void *dlsym(void *__handle, const char *__symbol)
{
  od::ElfFile *elf = (od::ElfFile *)__handle;
  return elf->lookup(__symbol);
}

namespace od
{
  // [stol:infra-crash-diag-module-map] am335x enumerator over the dlopen registry.
  // Reads mLoaded only; no allocation-after-first (vector may grow, but the
  // sibling's abort-context path should pre-size / read the map directly if it
  // needs allocation-free operation). Kernel is not relocated on am335x, so its
  // text base is 0 and PCs map directly onto the kernel .elf for addr2line.
  void enumerateModules(std::vector<ModuleInfo> &out)
  {
    out.clear();
    ModuleInfo kernel;
    kernel.path = "kernel";
    kernel.textBase = 0;
    kernel.textSize = 0;
    kernel.dataBase = 0;
    kernel.dataSize = 0;
    out.push_back(kernel);

    for (auto &kv : local.mLoaded)
    {
      od::ElfFile *elf = kv.second;
      if (!elf)
      {
        continue;
      }
      ModuleInfo m;
      m.path = elf->path();
      m.textBase = (uintptr_t)elf->textBase();
      m.textSize = elf->textSize();
      m.dataBase = (uintptr_t)elf->dataBase();
      m.dataSize = elf->dataSize();
      out.push_back(m);
    }
  }
}

// [stol:infra-crash-diag-exc-hook] Abort-safe companion to enumerateModules().
// Writes fixed-size POD entries into a caller-provided array: no std::vector,
// no std::string, no allocation, no locks — safe to call from the ARM exception
// hook. Entry 0 is the kernel (textBase 0 == not relocated), then every loaded
// package. Reads local.mLoaded only.
extern "C" int panicEnumerateModules(PanicModuleEntry *out, int maxEntries)
{
  if (!out || maxEntries <= 0)
  {
    return 0;
  }

  int n = 0;

  // Kernel entry first (matches enumerateModules()). textBase 0 tells the
  // offline symbolizer the PC is already an absolute kernel.elf address.
  strncpy(out[n].path, "kernel", sizeof(out[n].path) - 1);
  out[n].path[sizeof(out[n].path) - 1] = 0;
  out[n].textBase = 0;
  out[n].textSize = 0;
  out[n].dataBase = 0;
  out[n].dataSize = 0;
  n++;

  for (auto &kv : local.mLoaded)
  {
    if (n >= maxEntries)
    {
      break;
    }
    od::ElfFile *elf = kv.second;
    if (!elf)
    {
      continue;
    }
    const std::string &p = kv.first;
    strncpy(out[n].path, p.c_str(), sizeof(out[n].path) - 1);
    out[n].path[sizeof(out[n].path) - 1] = 0;
    out[n].textBase = (uintptr_t)elf->textBase();
    out[n].textSize = (uint32_t)elf->textSize();
    out[n].dataBase = (uintptr_t)elf->dataBase();
    out[n].dataSize = (uint32_t)elf->dataSize();
    n++;
  }

  return n;
}
