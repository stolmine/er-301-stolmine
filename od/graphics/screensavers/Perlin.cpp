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

  const int Perlin::contourThresholds[CONTOUR_LEVELS] = {
      36, 72, 108, 144, 180, 216};

  void Perlin::reset()
  {
    mTime = 0.0f;
    mDriftX = 0.0f;
    mDriftY = 0.0f;
    memset(mField, 0, sizeof(mField));
    memset(mWarpMag, 0, sizeof(mWarpMag));
    memset(mAbsorption, 0, sizeof(mAbsorption));

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

  void Perlin::draw(FrameBuffer &m, FrameBuffer &s)
  {
    mTime += GRAPHICS_REFRESH_PERIOD * 0.15f;

    // Modulate field characteristics over time
    float baseScale = 0.06f;
    float scaleWarp = sinf(mTime * 0.4f) * 0.01f;
    float noiseScale = baseScale + scaleWarp;

    // Domain warping
    float warpStrength = (sinf(mTime * 0.2f) * 0.5f + 0.5f) * 1.5f + 0.5f;

    // Drift direction evolves — integrate velocity so speed stays constant
    float dt = GRAPHICS_REFRESH_PERIOD * 0.15f;
    float driftVX = sinf(mTime * 0.17f) * 0.4f;
    float driftVY = cosf(mTime * 0.11f) * 0.4f;
    mDriftX += driftVX * dt;
    mDriftY += driftVY * dt;

    // Evaluate noise field and warp magnitude
    for (int gy = 0; gy < GRID_H; gy++)
    {
      for (int gx = 0; gx < GRID_W; gx++)
      {
        float nx = (float)gx * noiseScale + mDriftX;
        float ny = (float)gy * noiseScale + mDriftY;

        float wx = noise(nx + 5.2f, ny + 1.3f) * warpStrength;
        float wy = noise(nx + 9.7f, ny + 6.1f) * warpStrength;

        float val = fbm(nx + wx, ny + wy, 2);

        int ival = (int)((val + 0.5f) * 255.0f);
        if (ival < 0) ival = 0;
        if (ival > 255) ival = 255;
        mField[gy * GRID_W + gx] = (uint8_t)ival;

        // Warp magnitude: how deformed this cell is (0-255)
        float wm = sqrtf(wx * wx + wy * wy) / (warpStrength * 1.2f);
        if (wm > 1.0f) wm = 1.0f;
        mWarpMag[gy * GRID_W + gx] = (uint8_t)(wm * 255.0f);
      }
    }

    // Continuous absorption oscillator: slow sine sweeps 0→1→0
    // This is the "tide line" — cells with warp above it absorb into contour
    float sweep = sinf(mTime * 0.4f) * 0.5f + 0.5f; // 0-1, ~40s full cycle

    float absorbSpeed = GRAPHICS_REFRESH_PERIOD * 0.2f;

    for (int i = 0; i < GRID_W * GRID_H; i++)
    {
      float priority = (float)mWarpMag[i] / 255.0f;

      // Cell absorbs when its warp priority exceeds the sweep threshold
      // High-warp cells cross first as sweep rises, release last as it falls
      float cellTarget = (priority > (1.0f - sweep)) ? 1.0f : 0.0f;

      // Smooth ramp — warp-proportional speed for organic wavefront
      if (mAbsorption[i] < cellTarget)
      {
        mAbsorption[i] += absorbSpeed * (1.0f + priority * 2.0f);
        if (mAbsorption[i] > 1.0f) mAbsorption[i] = 1.0f;
      }
      else if (mAbsorption[i] > cellTarget)
      {
        mAbsorption[i] -= absorbSpeed * (1.0f + (1.0f - priority) * 2.0f);
        if (mAbsorption[i] < 0.0f) mAbsorption[i] = 0.0f;
      }
    }

    // --- Main display ---
    // Fill pass: brightness reduced by local absorption
    for (int y = 0; y < 64; y++)
    {
      int gy = y / 2;
      if (gy >= GRID_H) gy = GRID_H - 1;
      for (int x = 0; x < 256; x++)
      {
        int gx = x / 2;
        if (gx >= GRID_W) gx = GRID_W - 1;
        int idx = gy * GRID_W + gx;
        float ab = mAbsorption[idx];
        int val = mField[idx];
        int color = (int)((float)(val / 17) * (1.0f - ab));
        if (color > 0)
          m.pixel(color, x, y);
      }
    }

    // Contour pass: line brightness scaled by local absorption
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

      for (int cy = 0; cy < GRID_H - 1; cy++)
      {
        for (int cx = 0; cx < GRID_W - 1; cx++)
        {
          // Local absorption at this cell (average of corners)
          float ab = (mAbsorption[cy * GRID_W + cx] +
                      mAbsorption[cy * GRID_W + cx + 1] +
                      mAbsorption[(cy + 1) * GRID_W + cx] +
                      mAbsorption[(cy + 1) * GRID_W + cx + 1]) *
                     0.25f;

          int color = (int)((float)baseColor * ab);
          if (color < 1) continue;

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

    // Sub display (128x64): stipple where fill, contour where absorbed
    // Stipple pass: density scaled by (1 - absorption)
    for (int y = 0; y < 64; y++)
    {
      int gy = y / 2;
      if (gy >= GRID_H) gy = GRID_H - 1;
      for (int x = 0; x < 128; x++)
      {
        int gx = x;
        if (gx >= GRID_W) gx = GRID_W - 1;
        int idx = gy * GRID_W + gx;
        float ab = mAbsorption[idx];
        int val = (int)((float)mField[idx] * (1.0f - ab));

        int threshold = mPerm[(mPerm[x & 255] + y) & 255];
        if (val > threshold)
          s.pixel(WHITE, x, y);
      }
    }

    // Sub contour pass: low-res marching squares (step by 4 in grid space)
    static const int subStep = 4;
    static const int SUB_CONTOUR_LEVELS = 4;
    static const int subThresholds[SUB_CONTOUR_LEVELS] = {50, 100, 155, 205};

    for (int level = 0; level < SUB_CONTOUR_LEVELS; level++)
    {
      int thresh = subThresholds[level];

      for (int cy = 0; cy < GRID_H - subStep; cy += subStep)
      {
        for (int cx = 0; cx < GRID_W - subStep; cx += subStep)
        {
          // Average absorption across this coarse cell
          float ab = (mAbsorption[cy * GRID_W + cx] +
                      mAbsorption[cy * GRID_W + cx + subStep] +
                      mAbsorption[(cy + subStep) * GRID_W + cx] +
                      mAbsorption[(cy + subStep) * GRID_W + cx + subStep]) *
                     0.25f;
          if (ab < 0.01f) continue;

          int v00 = mField[cy * GRID_W + cx];
          int v10 = mField[cy * GRID_W + cx + subStep];
          int v01 = mField[(cy + subStep) * GRID_W + cx];
          int v11 = mField[(cy + subStep) * GRID_W + cx + subStep];

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
            ex[0] = (float)cx + t * subStep;
            ey[0] = (float)cy;
            eActive[0] = true;
          }
          if ((v10 >= thresh) != (v11 >= thresh))
          {
            float t = (float)(thresh - v10) / (float)(v11 - v10);
            ex[1] = (float)(cx + subStep);
            ey[1] = (float)cy + t * subStep;
            eActive[1] = true;
          }
          if ((v01 >= thresh) != (v11 >= thresh))
          {
            float t = (float)(thresh - v01) / (float)(v11 - v01);
            ex[2] = (float)cx + t * subStep;
            ey[2] = (float)(cy + subStep);
            eActive[2] = true;
          }
          if ((v00 >= thresh) != (v01 >= thresh))
          {
            float t = (float)(thresh - v00) / (float)(v01 - v00);
            ex[3] = (float)cx;
            ey[3] = (float)cy + t * subStep;
            eActive[3] = true;
          }

          // Sub display: grid coords map 1:1 horizontally, 2x vertically
          for (int si = 0; si < 4; si += 2)
          {
            if (segTable[config][si] < 0 || segTable[config][si + 1] < 0) continue;
            int a = segTable[config][si], b = segTable[config][si + 1];
            if (!eActive[a] || !eActive[b]) continue;

            int px0 = (int)(ex[a] + 0.5f);
            int py0 = (int)(ey[a] * 2.0f + 0.5f);
            int px1 = (int)(ex[b] + 0.5f);
            int py1 = (int)(ey[b] * 2.0f + 0.5f);

            if (px0 >= 0 && px0 < 128 && px1 >= 0 && px1 < 128 &&
                py0 >= 0 && py0 < 64 && py1 >= 0 && py1 < 64)
              s.line(WHITE, px0, py0, px1, py1);
          }
        }
      }
    }
  }

} /* namespace od */
