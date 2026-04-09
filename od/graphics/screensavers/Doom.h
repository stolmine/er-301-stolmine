#pragma once

#include <od/graphics/ScreenSaver.h>

namespace od
{

  class Doom : public ScreenSaver
  {
  public:
    Doom();
    virtual ~Doom();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    bool mInitialized = false;
    bool mWadMissing = false;
    float mTickAccum = 0.0f;
    int mDeathTimer = 0;
    float mBorderPhase = 0.0f;

    // Viewport: correct aspect ratio centered in 256x64
    static const int VP_HEIGHT = 64;
    static const int VP_WIDTH = 102;  // 64 * 320/200
    static const int VP_LEFT = (256 - VP_WIDTH) / 2; // 77

    // Precomputed LUTs for downscaling 320x200 → VP_WIDTH x VP_HEIGHT
    int mColLUT[VP_WIDTH];
    int mRowLUT[VP_HEIGHT];

    void initLUTs();
    void blitFrame(FrameBuffer &fb);
    void drawBorders(FrameBuffer &fb);
    void drawStatus(FrameBuffer &fb);
  };

} /* namespace od */
