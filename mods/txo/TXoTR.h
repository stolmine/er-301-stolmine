#pragma once

#include <od/objects/Object.h>
#include <txo/TXoDispatcher.h>

namespace txo
{

  class TXoTR : public od::Object
  {
  public:
    TXoTR(TXoDispatcher *pDispatcher);
    virtual ~TXoTR();

#ifndef SWIGLUA
    virtual void process();
    od::Inlet mInput{"In"};
    od::Outlet mOutput{"Out"};
    od::Parameter mPort{"Port", 0.0f};
    od::Parameter mThreshold{"Threshold", 0.1f};
#endif

  private:
    TXoDispatcher *mpDispatcher;
    bool mLastState = false;
  };

} // namespace txo
