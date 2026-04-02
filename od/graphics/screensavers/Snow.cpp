#include <od/graphics/screensavers/Snow.h>
#include <od/extras/Random.h>
#include <hal/constants.h>
#include <math.h>
#include <string.h>

namespace od
{

  Snow::Snow()
  {
    reset();
  }

  Snow::~Snow()
  {
  }

  void Snow::spawn(int i)
  {
    mX[i] = Random::generateFloat(0.0f, (float)(SNOW_MAIN_W - 1));
    mY[i] = (float)(SNOW_H - 1);
    mSpeed[i] = Random::generateFloat(0.3f, 1.0f);
    mWobble[i] = Random::generateFloat(0.0f, 6.28f);
    mSize[i] = Random::generateFloat(0.0f, 1.0f) < 0.15f ? 2 : 1;
    mActive[i] = true;
  }

  void Snow::reset()
  {
    memset(mActive, 0, sizeof(mActive));
    memset(mGround, 0, sizeof(mGround));
    memset(mGroundSub, 0, sizeof(mGroundSub));
    mMeltTimer = 0.0f;
  }

  void Snow::meltGround()
  {
    // Find the tallest columns and melt them
    for (int n = 0; n < 4; n++)
    {
      int tallest = 0;
      int tallestX = 0;
      for (int x = 0; x < SNOW_MAIN_W; x++)
      {
        if (mGround[x] > tallest)
        {
          tallest = mGround[x];
          tallestX = x;
        }
      }
      if (tallest > 0)
      {
        mGround[tallestX]--;
        int sx = tallestX / 2;
        if (sx < SNOW_SUB_W)
        {
          int a = mGround[sx * 2];
          int b = (sx * 2 + 1 < SNOW_MAIN_W) ? mGround[sx * 2 + 1] : 0;
          mGroundSub[sx] = (a > b) ? a : b;
        }
      }
    }
  }

  void Snow::draw(FrameBuffer &m, FrameBuffer &s)
  {
    // Spawn new flakes
    int toSpawn = Random::generateInteger(0, 2);
    for (int n = 0; n < toSpawn; n++)
    {
      for (int i = 0; i < SNOW_N; i++)
      {
        if (!mActive[i])
        {
          spawn(i);
          break;
        }
      }
    }

    // Update flakes
    for (int i = 0; i < SNOW_N; i++)
    {
      if (!mActive[i])
        continue;

      mWobble[i] += GRAPHICS_REFRESH_PERIOD * 3.0f;
      mX[i] += sinf(mWobble[i]) * 0.5f;
      mY[i] -= mSpeed[i];

      // Wrap x as float before casting
      if (mX[i] < 0.0f)
        mX[i] += (float)SNOW_MAIN_W;
      else if (mX[i] >= (float)SNOW_MAIN_W)
        mX[i] -= (float)SNOW_MAIN_W;

      int ix = (int)mX[i];
      int iy = (int)mY[i];

      // Check if landed on ground (cap ground at screen height)
      int groundLevel = mGround[ix];
      if (groundLevel < SNOW_H && iy <= groundLevel)
      {
        mActive[i] = false;
        mGround[ix]++;
        int sx = ix / 2;
        if (sx < SNOW_SUB_W)
        {
          if (mGround[ix] > mGroundSub[sx])
            mGroundSub[sx] = mGround[ix];
        }
      }
      else if (groundLevel >= SNOW_H)
      {
        // Column is full, flake drifts off
        mActive[i] = false;
      }
    }

    // Melt ground gradually once it starts accumulating
    mMeltTimer += GRAPHICS_REFRESH_PERIOD;
    if (mMeltTimer >= 0.1f)
    {
      mMeltTimer = 0.0f;
      meltGround();
    }

    // Draw falling flakes
    for (int i = 0; i < SNOW_N; i++)
    {
      if (!mActive[i])
        continue;
      int ix = (int)mX[i];
      int iy = (int)mY[i];
      int sz = mSize[i];
      if (iy >= 0 && iy < SNOW_H && ix >= 0 && ix < SNOW_MAIN_W)
      {
        m.pixel(WHITE, ix, iy);
        if (sz > 1)
        {
          if (ix + 1 < SNOW_MAIN_W) m.pixel(WHITE, ix + 1, iy);
          if (iy + 1 < SNOW_H) m.pixel(WHITE, ix, iy + 1);
        }
      }
      int sx = ix / 2;
      if (iy >= 0 && iy < SNOW_H && sx >= 0 && sx < SNOW_SUB_W)
      {
        s.pixel(WHITE, sx, iy);
      }
    }

    // Draw ground
    for (int x = 0; x < SNOW_MAIN_W; x++)
    {
      for (int g = 0; g < mGround[x] && g < SNOW_H; g++)
      {
        m.pixel(WHITE, x, g);
      }
    }
    for (int x = 0; x < SNOW_SUB_W; x++)
    {
      for (int g = 0; g < mGroundSub[x] && g < SNOW_H; g++)
      {
        s.pixel(WHITE, x, g);
      }
    }
  }

} /* namespace od */
