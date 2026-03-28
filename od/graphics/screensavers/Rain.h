#pragma once

#include <od/graphics/ScreenSaver.h>

namespace od
{

#define RAIN_N 48
#define SPLASH_N 12
#define RAIN_MAIN_W 256
#define RAIN_H 64

  class Rain : public ScreenSaver
  {
  public:
    Rain();
    virtual ~Rain();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    void spawn(int i);

    float mX[RAIN_N], mY[RAIN_N], mSpeed[RAIN_N];
    int mLength[RAIN_N], mBrightness[RAIN_N];
    bool mActive[RAIN_N];

    int mSplashX[SPLASH_N], mSplashTimer[SPLASH_N];
  };

} /* namespace od */
