#pragma once

#include <od/objects/Object.h>
#include <txo/TXoDispatcher.h>

namespace txo
{

  class TXoCV : public od::Object
  {
  public:
    TXoCV(TXoDispatcher *pDispatcher);
    virtual ~TXoCV();

#ifndef SWIGLUA
    virtual void process();
    od::Inlet mInput{"In"};
    od::Outlet mOutput{"Out"};
    od::Parameter mPort{"Port", 0.0f};
#endif

  private:
    TXoDispatcher *mpDispatcher;
  };

} // namespace txo
