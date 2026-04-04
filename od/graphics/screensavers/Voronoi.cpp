#include <od/graphics/screensavers/Voronoi.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cmath>
#include <cstring>

namespace od
{

  Voronoi::Voronoi()
  {
    mLightTime = 0.0f;
    reset();
  }

  Voronoi::~Voronoi()
  {
  }

  // Minimal perlin for light field
  float Voronoi::pFade(float t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
  float Voronoi::pLerp(float a, float b, float t) { return a + t * (b - a); }
  float Voronoi::pGrad(int hash, float x, float y)
  {
    int h = hash & 7;
    float u = h < 4 ? x : y;
    float v = h < 4 ? y : x;
    return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
  }

  float Voronoi::pNoise(float x, float y)
  {
    int xi = (int)floorf(x) & 255;
    int yi = (int)floorf(y) & 255;
    float xf = x - floorf(x);
    float yf = y - floorf(y);
    float u = pFade(xf);
    float v = pFade(yf);
    int aa = mPerm[mPerm[xi] + yi];
    int ab = mPerm[mPerm[xi] + yi + 1];
    int ba = mPerm[mPerm[xi + 1] + yi];
    int bb = mPerm[mPerm[xi + 1] + yi + 1];
    return pLerp(
        pLerp(pGrad(aa, xf, yf), pGrad(ba, xf - 1.0f, yf), u),
        pLerp(pGrad(ab, xf, yf - 1.0f), pGrad(bb, xf - 1.0f, yf - 1.0f), u),
        v);
  }

  void Voronoi::addSeed(float x, float y, int depth)
  {
    if (mSeedCount >= MAX_SEEDS) return;
    Seed &s = mSeeds[mSeedCount++];
    s.x = x;
    s.y = y;
    s.vx = Random::generateFloat(-0.3f, 0.3f);
    s.vy = Random::generateFloat(-0.15f, 0.15f);
    s.radius = 0.0f;
    s.maxRadius = 200.0f;
    s.depth = depth;
    s.active = true;
  }

  void Voronoi::rebuildField()
  {
    for (int y = 0; y < GRID_H; y++)
    {
      for (int x = 0; x < GRID_W; x++)
      {
        float minDist = 1e9f;
        float minDist2 = 1e9f;
        uint16_t owner = 0;
        float px = (float)x;
        float py = (float)y;

        for (int i = 0; i < mSeedCount; i++)
        {
          if (!mSeeds[i].active) continue;
          float dx = px - mSeeds[i].x;
          float dy = py - mSeeds[i].y;
          float d = dx * dx + dy * dy;

          if (d > mSeeds[i].radius * mSeeds[i].radius) continue;

          if (d < minDist)
          {
            minDist2 = minDist;
            minDist = d;
            owner = (uint16_t)i;
          }
          else if (d < minDist2)
          {
            minDist2 = d;
          }
        }
        mField[y * GRID_W + x] = owner;
        mDist[y * GRID_W + x] = sqrtf(minDist);

        // Edge proximity: how close are the two nearest seeds in distance?
        // If fewer than 2 seeds cover this pixel, no edge exists
        float edge = 0.0f;
        if (minDist < 1e8f && minDist2 < 1e8f)
        {
          float d1 = sqrtf(minDist);
          float d2 = sqrtf(minDist2);
          float smoothWidth = 1.5f;
          edge = 1.0f - (d2 - d1) / smoothWidth;
          if (edge < 0.0f) edge = 0.0f;
          if (edge > 1.0f) edge = 1.0f;
        }
        mEdge[y * GRID_W + x] = edge;
      }
    }
  }

  void Voronoi::reset()
  {
    mSeedCount = 0;
    mTimer = 0.0f;
    mSpawnTimer = 0.0f;
    mFadeOut = 0.0f;
    mCurrentDepth = 0;
    mPhase = SUBDIVIDING;
    memset(mField, 0, sizeof(mField));
    memset(mDist, 0, sizeof(mDist));
    memset(mEdge, 0, sizeof(mEdge));

    // Initialize permutation table for light field
    for (int i = 0; i < 256; i++)
      mPerm[i] = i;
    for (int i = 255; i > 0; i--)
    {
      int j = Random::generateInteger(0, i);
      int tmp = mPerm[i];
      mPerm[i] = mPerm[j];
      mPerm[j] = tmp;
    }
    for (int i = 0; i < 256; i++)
      mPerm[i + 256] = mPerm[i];

    int initial = 3 + Random::generateInteger(0, 2);
    for (int i = 0; i < initial; i++)
    {
      addSeed(Random::generateFloat(10.0f, 118.0f),
              Random::generateFloat(4.0f, 28.0f), 0);
    }
  }

  void Voronoi::draw(FrameBuffer &m, FrameBuffer &s)
  {
    float dt = GRAPHICS_REFRESH_PERIOD;
    mTimer += dt;
    mLightTime += dt;

    // Drift seeds
    for (int i = 0; i < mSeedCount; i++)
    {
      if (!mSeeds[i].active) continue;
      mSeeds[i].x += mSeeds[i].vx * dt;
      mSeeds[i].y += mSeeds[i].vy * dt;

      if (mSeeds[i].x < 1.0f) { mSeeds[i].x = 1.0f; mSeeds[i].vx = fabsf(mSeeds[i].vx); }
      if (mSeeds[i].x > GRID_W - 2.0f) { mSeeds[i].x = GRID_W - 2.0f; mSeeds[i].vx = -fabsf(mSeeds[i].vx); }
      if (mSeeds[i].y < 1.0f) { mSeeds[i].y = 1.0f; mSeeds[i].vy = fabsf(mSeeds[i].vy); }
      if (mSeeds[i].y > GRID_H - 2.0f) { mSeeds[i].y = GRID_H - 2.0f; mSeeds[i].vy = -fabsf(mSeeds[i].vy); }

      if (mSeeds[i].radius < mSeeds[i].maxRadius)
      {
        float growSpeed = 8.0f + (float)mSeeds[i].depth * 2.0f;
        mSeeds[i].radius += dt * growSpeed;
        if (mSeeds[i].radius > mSeeds[i].maxRadius)
          mSeeds[i].radius = mSeeds[i].maxRadius;
      }
    }

    // Subdivision spawning
    switch (mPhase)
    {
    case SUBDIVIDING:
    {
      mSpawnTimer += dt;
      float interval = 1.2f - (float)mCurrentDepth * 0.12f;
      if (interval < 0.2f) interval = 0.2f;

      if (mSpawnTimer >= interval)
      {
        mSpawnTimer = 0.0f;
        int attempts = 0;
        bool spawned = false;
        while (attempts < 30 && !spawned)
        {
          float nx = Random::generateFloat(3.0f, GRID_W - 4.0f);
          float ny = Random::generateFloat(2.0f, GRID_H - 3.0f);

          float minDist = 1e9f;
          for (int i = 0; i < mSeedCount; i++)
          {
            float dx = nx - mSeeds[i].x;
            float dy = ny - mSeeds[i].y;
            float d = dx * dx + dy * dy;
            if (d < minDist) minDist = d;
          }

          float minSpacing = 16.0f - (float)mCurrentDepth * 2.0f;
          if (minSpacing < 3.0f) minSpacing = 3.0f;

          if (minDist > minSpacing * minSpacing)
          {
            addSeed(nx, ny, mCurrentDepth);
            spawned = true;
          }
          attempts++;
        }

        if (!spawned)
        {
          mCurrentDepth++;
          if (mCurrentDepth >= MAX_DEPTH)
          {
            mPhase = HOLDING;
            mTimer = 0.0f;
          }
        }
      }
      break;
    }
    case HOLDING:
      if (mTimer >= 4.0f)
      {
        mPhase = FADING;
        mTimer = 0.0f;
      }
      break;

    case FADING:
      mFadeOut += dt * 0.25f;
      if (mFadeOut >= 1.0f)
        reset();
      break;
    }

    rebuildField();

    // --- Main display (256x64) ---
    // Bilinear interpolation of edge proximity for smooth anti-aliased lines
    for (int y = 0; y < 64; y++)
    {
      // Fractional grid position
      float fy = (float)y * 0.5f;
      int gy0 = (int)fy;
      int gy1 = gy0 + 1;
      float fy_frac = fy - (float)gy0;
      if (gy0 >= GRID_H) gy0 = GRID_H - 1;
      if (gy1 >= GRID_H) gy1 = GRID_H - 1;

      for (int x = 0; x < 256; x++)
      {
        float fx = (float)x * 0.5f;
        int gx0 = (int)fx;
        int gx1 = gx0 + 1;
        float fx_frac = fx - (float)gx0;
        if (gx0 >= GRID_W) gx0 = GRID_W - 1;
        if (gx1 >= GRID_W) gx1 = GRID_W - 1;

        // Bilinear sample of edge proximity
        float e00 = mEdge[gy0 * GRID_W + gx0];
        float e10 = mEdge[gy0 * GRID_W + gx1];
        float e01 = mEdge[gy1 * GRID_W + gx0];
        float e11 = mEdge[gy1 * GRID_W + gx1];

        float eTop = e00 + (e10 - e00) * fx_frac;
        float eBot = e01 + (e11 - e01) * fx_frac;
        float edge = eTop + (eBot - eTop) * fy_frac;

        if (edge < 0.02f) continue;

        // Perlin light field: slow-moving spotlights
        float lx = (float)x * 0.02f + mLightTime * 0.3f;
        float ly = (float)y * 0.04f + mLightTime * 0.2f;
        float light = pNoise(lx, ly) + 0.5f;
        light += pNoise(lx * 2.1f + 7.0f, ly * 2.1f + 3.0f) * 0.3f;
        if (light < 0.0f) light = 0.0f;
        if (light > 1.0f) light = 1.0f;

        // Owner for depth lookup
        int gx = (int)(fx + 0.5f);
        int gy = (int)(fy + 0.5f);
        if (gx >= GRID_W) gx = GRID_W - 1;
        if (gy >= GRID_H) gy = GRID_H - 1;
        uint16_t owner = mField[gy * GRID_W + gx];
        int depth = mSeeds[owner].depth;

        float baseBright = (float)(WHITE - depth * 2);
        if (baseBright < (float)GRAY3) baseBright = (float)GRAY3;

        int color = (int)(baseBright * edge * light);
        if (color < 1 && edge > 0.1f) color = 1;

        if (mPhase == FADING)
          color = (int)((float)color * (1.0f - mFadeOut));

        if (color > 0)
          m.pixel(color, x, y);
      }
    }

    // --- Sub display (128x64): thin edges ---
    for (int y = 0; y < 64; y++)
    {
      int gy = y / 2;
      if (gy >= GRID_H) gy = GRID_H - 1;
      int gyN = (y > 0) ? (y - 1) / 2 : 0;
      int gyS = (y < 63) ? (y + 1) / 2 : GRID_H - 1;
      if (gyN >= GRID_H) gyN = GRID_H - 1;
      if (gyS >= GRID_H) gyS = GRID_H - 1;

      for (int x = 0; x < 128; x++)
      {
        int gx = x;
        if (gx >= GRID_W) gx = GRID_W - 1;

        uint16_t owner = mField[gy * GRID_W + gx];

        int gxW = (x > 0) ? x - 1 : 0;
        int gxE = (x < 127) ? x + 1 : GRID_W - 1;
        if (gxE >= GRID_W) gxE = GRID_W - 1;

        bool edge = (mField[gy * GRID_W + gxW] != owner) ||
                    (mField[gy * GRID_W + gxE] != owner) ||
                    (mField[gyN * GRID_W + gx] != owner) ||
                    (mField[gyS * GRID_W + gx] != owner);

        if (edge)
        {
          if (mPhase == FADING && mFadeOut > 0.9f) continue;
          s.pixel(WHITE, x, y);
        }
      }
    }
  }

} /* namespace od */
