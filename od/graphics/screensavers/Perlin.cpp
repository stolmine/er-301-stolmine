#include <od/graphics/screensavers/Perlin.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cmath>
#include <cstring>

namespace od
{

  Perlin::Perlin()
  {
    reset();
  }

  Perlin::~Perlin()
  {
  }

  float Perlin::fade(float t)
  {
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
  }

  float Perlin::lerp(float a, float b, float t)
  {
    return a + t * (b - a);
  }

  float Perlin::grad(int hash, float x, float y)
  {
    int h = hash & 7;
    float u = h < 4 ? x : y;
    float v = h < 4 ? y : x;
    return ((h & 1) ? -u : u) + ((h & 2) ? -v : v);
  }

  float Perlin::noise(float x, float y)
  {
    int xi = (int)floorf(x) & 255;
    int yi = (int)floorf(y) & 255;
    float xf = x - floorf(x);
    float yf = y - floorf(y);
    float u = fade(xf);
    float v = fade(yf);

    int aa = mPerm[mPerm[xi] + yi];
    int ab = mPerm[mPerm[xi] + yi + 1];
    int ba = mPerm[mPerm[xi + 1] + yi];
    int bb = mPerm[mPerm[xi + 1] + yi + 1];

    return lerp(
        lerp(grad(aa, xf, yf), grad(ba, xf - 1.0f, yf), u),
        lerp(grad(ab, xf, yf - 1.0f), grad(bb, xf - 1.0f, yf - 1.0f), u),
        v);
  }

  float Perlin::fbm(float x, float y, int octaves)
  {
    float val = 0.0f;
    float amp = 0.5f;
    float freq = 1.0f;
    for (int i = 0; i < octaves; i++)
    {
      val += noise(x * freq, y * freq) * amp;
      freq *= 2.0f;
      amp *= 0.5f;
    }
    return val;
  }

  // Evenly spaced contour thresholds across the 0-255 field range
  const int Perlin::contourThresholds[CONTOUR_LEVELS] = {
      36, 72, 108, 144, 180, 216};

  void Perlin::reset()
  {
    mTime = 0.0f;
    mBlend = 0.0f;
    mBlendTarget = 0.0f;
    mHoldTimer = 0.0f;
    memset(mField, 0, sizeof(mField));

    // Initialize permutation table
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
  }

  void Perlin::drawMain(FrameBuffer &m, float blend)
  {
    float fillAmt = 1.0f - blend;
    float contourAmt = blend;

    // Fill pass: brightness scaled by (1 - blend)
    if (fillAmt > 0.01f)
    {
      for (int y = 0; y < 64; y++)
      {
        int gy = y / 2;
        if (gy >= GRID_H) gy = GRID_H - 1;
        for (int x = 0; x < 256; x++)
        {
          int gx = x / 2;
          if (gx >= GRID_W) gx = GRID_W - 1;
          int val = mField[gy * GRID_W + gx];
          int color = (int)((float)(val / 17) * fillAmt);
          if (color > 0)
            m.pixel(color, x, y);
        }
      }
    }

    // Contour pass: line brightness scaled by blend
    if (contourAmt > 0.01f)
    {
      static const int segTable[16][4] = {
          {-1, -1, -1, -1}, {0, 3, -1, -1}, {0, 1, -1, -1}, {1, 3, -1, -1},
          {2, 3, -1, -1}, {0, 1, 2, 3}, {0, 2, -1, -1}, {1, 2, -1, -1},
          {1, 2, -1, -1}, {0, 2, -1, -1}, {0, 3, 1, 2}, {1, 2, -1, -1},
          {1, 3, -1, -1}, {0, 1, -1, -1}, {0, 3, -1, -1}, {-1, -1, -1, -1}};

      for (int level = 0; level < CONTOUR_LEVELS; level++)
      {
        int thresh = contourThresholds[level];
        int baseColor = GRAY3 + level * 2;
        if (baseColor > WHITE) baseColor = WHITE;
        int color = (int)((float)baseColor * contourAmt);
        if (color < 1) continue;

        for (int cy = 0; cy < GRID_H - 1; cy++)
        {
          for (int cx = 0; cx < GRID_W - 1; cx++)
          {
            int v00 = mField[cy * GRID_W + cx];
            int v10 = mField[cy * GRID_W + cx + 1];
            int v01 = mField[(cy + 1) * GRID_W + cx];
            int v11 = mField[(cy + 1) * GRID_W + cx + 1];

            int config = 0;
            if (v00 >= thresh) config |= 1;
            if (v10 >= thresh) config |= 2;
            if (v01 >= thresh) config |= 4;
            if (v11 >= thresh) config |= 8;

            if (config == 0 || config == 15) continue;

            float ex[4], ey[4];
            bool eActive[4] = {false, false, false, false};

            if ((v00 >= thresh) != (v10 >= thresh))
            {
              float t = (float)(thresh - v00) / (float)(v10 - v00);
              ex[0] = (float)cx + t;
              ey[0] = (float)cy;
              eActive[0] = true;
            }
            if ((v10 >= thresh) != (v11 >= thresh))
            {
              float t = (float)(thresh - v10) / (float)(v11 - v10);
              ex[1] = (float)(cx + 1);
              ey[1] = (float)cy + t;
              eActive[1] = true;
            }
            if ((v01 >= thresh) != (v11 >= thresh))
            {
              float t = (float)(thresh - v01) / (float)(v11 - v01);
              ex[2] = (float)cx + t;
              ey[2] = (float)(cy + 1);
              eActive[2] = true;
            }
            if ((v00 >= thresh) != (v01 >= thresh))
            {
              float t = (float)(thresh - v00) / (float)(v01 - v00);
              ex[3] = (float)cx;
              ey[3] = (float)cy + t;
              eActive[3] = true;
            }

            const int *segs = segTable[config];

            for (int si = 0; si < 4; si += 2)
            {
              if (segs[si] < 0 || segs[si + 1] < 0) continue;
              if (!eActive[segs[si]] || !eActive[segs[si + 1]]) continue;

              int px0 = (int)(ex[segs[si]] * 2.0f + 0.5f);
              int py0 = (int)(ey[segs[si]] * 2.0f + 0.5f);
              int px1 = (int)(ex[segs[si + 1]] * 2.0f + 0.5f);
              int py1 = (int)(ey[segs[si + 1]] * 2.0f + 0.5f);

              m.line(color, px0, py0, px1, py1);
            }
          }
        }
      }
    }
  }

  void Perlin::draw(FrameBuffer &m, FrameBuffer &s)
  {
    mTime += GRAPHICS_REFRESH_PERIOD * 0.15f;

    // Crossfade: hold at each extreme, then ramp to the other
    mHoldTimer += GRAPHICS_REFRESH_PERIOD;
    float holdDuration = 20.0f;
    float rampSpeed = 0.12f; // ~8 seconds full crossfade

    if (mHoldTimer >= holdDuration)
    {
      // Flip target
      mBlendTarget = (mBlendTarget < 0.5f) ? 1.0f : 0.0f;
      mHoldTimer = 0.0f;
    }

    // Ramp toward target
    if (mBlend < mBlendTarget)
    {
      mBlend += GRAPHICS_REFRESH_PERIOD * rampSpeed;
      if (mBlend > mBlendTarget) mBlend = mBlendTarget;
    }
    else if (mBlend > mBlendTarget)
    {
      mBlend -= GRAPHICS_REFRESH_PERIOD * rampSpeed;
      if (mBlend < mBlendTarget) mBlend = mBlendTarget;
    }

    // Modulate field characteristics over time
    float baseScale = 0.06f;
    float scaleWarp = sinf(mTime * 0.4f) * 0.01f;
    float noiseScale = baseScale + scaleWarp;

    // Domain warping: single-octave noise for broad, smooth distortion
    float warpStrength = (sinf(mTime * 0.2f) * 0.5f + 0.5f) * 1.5f + 0.5f;

    // Drift direction evolves over time
    float driftX = sinf(mTime * 0.17f) * 0.4f;
    float driftY = cosf(mTime * 0.11f) * 0.4f;

    // Evaluate noise field
    for (int gy = 0; gy < GRID_H; gy++)
    {
      for (int gx = 0; gx < GRID_W; gx++)
      {
        float nx = (float)gx * noiseScale + mTime * driftX;
        float ny = (float)gy * noiseScale + mTime * driftY;

        float wx = noise(nx + 5.2f, ny + 1.3f) * warpStrength;
        float wy = noise(nx + 9.7f, ny + 6.1f) * warpStrength;

        float val = fbm(nx + wx, ny + wy, 2);

        int ival = (int)((val + 0.5f) * 255.0f);
        if (ival < 0) ival = 0;
        if (ival > 255) ival = 255;
        mField[gy * GRID_W + gx] = (uint8_t)ival;
      }
    }

    // Main display: crossfade between fill and contour
    drawMain(m, mBlend);

    // Sub display (128x64): stippled density
    for (int y = 0; y < 64; y++)
    {
      int gy = y / 2;
      if (gy >= GRID_H) gy = GRID_H - 1;
      for (int x = 0; x < 128; x++)
      {
        int gx = x;
        if (gx >= GRID_W) gx = GRID_W - 1;
        int val = mField[gy * GRID_W + gx];

        int threshold = mPerm[(mPerm[x & 255] + y) & 255];
        if (val > threshold)
          s.pixel(WHITE, x, y);
      }
    }
  }

} /* namespace od */
