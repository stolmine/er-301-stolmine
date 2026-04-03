#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Perlin : public ScreenSaver
  {
  public:
    Perlin();
    virtual ~Perlin();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    static float fade(float t);
    static float lerp(float a, float b, float t);
    static float grad(int hash, float x, float y);
    float noise(float x, float y);
    float fbm(float x, float y, int octaves);

    // Evaluate at half resolution (128x32) and upscale 2x
    static const int GRID_W = 128;
    static const int GRID_H = 32;

    static const int CONTOUR_LEVELS = 6;
    static const int contourThresholds[CONTOUR_LEVELS];

    int mPerm[512];
    uint8_t mField[GRID_W * GRID_H];     // noise value 0-255
    uint8_t mWarpMag[GRID_W * GRID_H];   // warp magnitude 0-255
    float mAbsorption[GRID_W * GRID_H];  // per-cell absorption 0-1
    float mTime;
  };

} /* namespace od */
