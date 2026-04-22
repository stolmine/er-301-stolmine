#pragma once

#include <od/objects/Object.h>

namespace multiout
{

  // Quadrature LFO: one phase accumulator drives four sine outputs at
  // 0/90/180/270 degrees. Test fixture for the multi-output unit framework
  // (see docs/planning/redesign/07-multi-output-units.md).
  //
  // Vanilla-compatible: inherits od::Object, uses only standard Inlet/Outlet/
  // Parameter primitives present in upstream ER-301. The Lua wrapper sets
  // optional `subOutLabels` metadata that vanilla firmware ignores.
  class QuadLFO : public od::Object
  {
  public:
    QuadLFO();
    virtual ~QuadLFO();

#ifndef SWIGLUA
    virtual void process();
    od::Inlet mFrequency{"Frequency"};
    od::Inlet mSync{"Sync"};
    od::Outlet mOut1{"Out1"}; //   0°
    od::Outlet mOut2{"Out2"}; //  90°
    od::Outlet mOut3{"Out3"}; // 180°
    od::Outlet mOut4{"Out4"}; // 270°
    od::Parameter mInternalPhase{"Internal Phase", 0.0f};
#endif
  };

} // namespace multiout
