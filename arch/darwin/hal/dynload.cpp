#include <hal/modulemap.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/machine.h>

namespace
{
  void addImage(const mach_header *header, intptr_t slide, const char *name,
                od::ModuleInfo &module)
  {
    module.path = name == nullptr || name[0] == '\0' ? "kernel" : name;
    module.textBase = 0;
    module.textSize = 0;
    module.dataBase = 0;
    module.dataSize = 0;

    if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64)
    {
      const auto *header64 = reinterpret_cast<const mach_header_64 *>(header);
      const auto *command = reinterpret_cast<const load_command *>(header64 + 1);
      for (uint32_t i = 0; i < header64->ncmds; ++i)
      {
        if (command->cmd == LC_SEGMENT_64)
        {
          const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
          const uintptr_t base = static_cast<uintptr_t>(slide) + segment->vmaddr;
          if ((segment->initprot & VM_PROT_EXECUTE) != 0)
          {
            module.textBase = base;
            module.textSize = segment->vmsize;
          }
          else if ((segment->initprot & VM_PROT_WRITE) != 0 && module.dataSize == 0)
          {
            module.dataBase = base;
            module.dataSize = segment->vmsize;
          }
        }
        command = reinterpret_cast<const load_command *>(
            reinterpret_cast<const uint8_t *>(command) + command->cmdsize);
      }
    }
  }
}

namespace od
{
  void enumerateModules(std::vector<ModuleInfo> &out)
  {
    out.clear();
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; ++i)
    {
      ModuleInfo module;
      addImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i),
               _dyld_get_image_name(i), module);
      out.push_back(module);
    }

    if (out.empty())
    {
      ModuleInfo kernel;
      kernel.path = "kernel";
      kernel.textBase = 0;
      kernel.textSize = 0;
      kernel.dataBase = 0;
      kernel.dataSize = 0;
      out.push_back(kernel);
    }
  }
}