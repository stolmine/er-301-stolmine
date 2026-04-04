#include "ElfFile.h"
#include "dlfcn.h"
#define BUILDOPT_VERBOSE
#define BUILDOPT_DEBUG_LEVEL 10
#include <hal/log.h>
#include <map>
#include <string>

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
