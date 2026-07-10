#ifndef __ElfFile_H__
#define __ElfFile_H__

#include <od/extras/ReferenceCounted.h>
#include <hal/dynload/SymbolTable.h>
#include <string>
#include <vector>

namespace od
{

  class ElfFile : public ReferenceCounted
  {
  public:
    ElfFile();
    ~ElfFile();

    bool load(const std::string &filename);
    bool unload();
    void *lookup(const std::string &symbol);
    std::vector<std::string> glob(const std::string &pattern);
    const std::string &path()
    {
      return mFilename;
    }
    const std::string &lastError()
    {
      return mLastError;
    }

    // [stol:infra-crash-diag-module-map] Public accessors for the loaded segment
    // bases/sizes so dlfcn's enumerator can emit the crash-report module map.
    // Appended (ABI-safe): ElfFile is internal firmware, never SWIG-exposed.
    const uint8_t *textBase() const
    {
      return mpTextSpace;
    }
    size_t textSize() const
    {
      return mTextSize;
    }
    const uint8_t *dataBase() const
    {
      return mpDataSpace;
    }
    size_t dataSize() const
    {
      return mDataSize;
    }

  protected:
    std::string mFilename;
    std::string mLastError;
    SymbolTable mSymbols;
    uint8_t *mpTextSpace = 0;
    uint8_t *mpDataSpace = 0;
    size_t mTextSize = 0;
    size_t mDataSize = 0;

    bool allocateTextSpace(size_t bytes);
    bool allocateDataSpace(size_t bytes);
    void freeTextSpace();
    void freeDataSpace();
  };

} // namespace od

#endif // __ElfFile_H__