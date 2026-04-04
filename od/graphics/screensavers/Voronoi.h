#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Voronoi : public ScreenSaver
  {
  public:
    Voronoi();
    virtual ~Voronoi();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    void addSeed(float x, float y, int depth);
    void rebuildField();

    // Perlin light field
    static float pFade(float t);
    static float pLerp(float a, float b, float t);
    static float pGrad(int hash, float x, float y);
    float pNoise(float x, float y);
    int mPerm[512];

    // Evaluate at half res, upscale 2x
    static const int GRID_W = 128;
    static const int GRID_H = 32;
    static const int MAX_SEEDS = 256;
    static const int MAX_DEPTH = 6;

    struct Seed
    {
      float x, y;       // position in grid space
      float vx, vy;     // drift velocity
      float radius;     // growth radius (grid units)
      float maxRadius;  // target radius (large = fully grown)
      int depth;
      bool active;
    };

    Seed mSeeds[MAX_SEEDS];
    int mSeedCount;
    uint16_t mField[GRID_W * GRID_H]; // owner index per pixel
    float mDist[GRID_W * GRID_H];     // distance to nearest seed
    float mEdge[GRID_W * GRID_H];     // edge proximity 0-1

    float mTimer;
    float mSpawnTimer;
    float mFadeOut;
    float mLightTime;     // monotonic time for perlin light field
    int mCurrentDepth;

    enum Phase { SUBDIVIDING, HOLDING, FADING };
    Phase mPhase;
  };

} /* namespace od */
