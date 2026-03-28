#pragma once

#include <od/graphics/ScreenSaver.h>

namespace od
{

#define SNOW_N 64
#define SNOW_MAIN_W 256
#define SNOW_SUB_W 128
#define SNOW_H 64

  class Snow : public ScreenSaver
  {
  public:
    Snow();
    virtual ~Snow();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    enum Phase
    {
      SNOWING,
      HOLDING,
      FADING
    };

    void spawn(int i);

    float mX[SNOW_N], mY[SNOW_N], mSpeed[SNOW_N], mWobble[SNOW_N];
    bool mActive[SNOW_N];
    int mGround[SNOW_MAIN_W];
    int mGroundSub[SNOW_SUB_W];
    Phase mPhase;
    float mHoldTimer;
    float mFadeLevel;
    int mMaxGround;
  };

} /* namespace od */
