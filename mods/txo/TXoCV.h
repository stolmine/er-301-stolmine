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
    od::Parameter mGain{"Gain", 1.0f};
    od::Option mMode{"Mode", 0}; // 0 = Normal, 1 = V/Oct
#endif

  private:
    TXoDispatcher *mpDispatcher;
  };

} // namespace txo
