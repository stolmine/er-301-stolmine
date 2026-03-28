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
    mActive[i] = true;
  }

  void Snow::reset()
  {
    memset(mActive, 0, sizeof(mActive));
    memset(mGround, 0, sizeof(mGround));
    memset(mGroundSub, 0, sizeof(mGroundSub));
    mPhase = SNOWING;
    mHoldTimer = 0.0f;
    mFadeLevel = 0.0f;
    mMaxGround = 0;
  }

  void Snow::draw(FrameBuffer &m, FrameBuffer &s)
  {
    switch (mPhase)
    {
    case SNOWING:
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

        int ix = (int)mX[i];
        int iy = (int)mY[i];

        // Wrap x
        if (ix < 0)
          ix += SNOW_MAIN_W;
        if (ix >= SNOW_MAIN_W)
          ix -= SNOW_MAIN_W;
        mX[i] = (float)ix;

        // Check if landed on ground
        int groundLevel = mGround[ix];
        if (iy <= groundLevel)
        {
          mActive[i] = false;
          mGround[ix]++;
          int sx = ix / 2;
          if (sx < SNOW_SUB_W)
          {
            if (mGround[ix] > mGroundSub[sx])
              mGroundSub[sx] = mGround[ix];
          }
          if (mGround[ix] > mMaxGround)
            mMaxGround = mGround[ix];
        }
      }

      // Transition when ground builds up
      if (mMaxGround >= 10)
      {
        mPhase = HOLDING;
        mHoldTimer = 0.0f;
      }
      break;
    }
    case HOLDING:
      mHoldTimer += GRAPHICS_REFRESH_PERIOD;
      if (mHoldTimer >= 4.0f)
      {
        mPhase = FADING;
        mFadeLevel = 0.0f;
      }
      break;
    case FADING:
      mFadeLevel += GRAPHICS_REFRESH_PERIOD / 2.0f;
      if (mFadeLevel >= 1.0f)
      {
        reset();
        return;
      }
      break;
    }

    // Compute fade color
    int colorVal = WHITE;
    if (mPhase == FADING)
    {
      colorVal = WHITE - (int)(mFadeLevel * WHITE);
      if (colorVal < 0)
        colorVal = 0;
    }

    // Draw falling flakes
    for (int i = 0; i < SNOW_N; i++)
    {
      if (!mActive[i])
        continue;
      int ix = (int)mX[i];
      int iy = (int)mY[i];
      if (iy >= 0 && iy < SNOW_H && ix >= 0 && ix < SNOW_MAIN_W)
      {
        m.pixel(colorVal, ix, iy);
      }
      int sx = ix / 2;
      if (iy >= 0 && iy < SNOW_H && sx >= 0 && sx < SNOW_SUB_W)
      {
        s.pixel(colorVal, sx, iy);
      }
    }

    // Draw ground
    for (int x = 0; x < SNOW_MAIN_W; x++)
    {
      for (int g = 0; g < mGround[x] && g < SNOW_H; g++)
      {
        m.pixel(colorVal, x, g);
      }
    }
    for (int x = 0; x < SNOW_SUB_W; x++)
    {
      for (int g = 0; g < mGroundSub[x] && g < SNOW_H; g++)
      {
        s.pixel(colorVal, x, g);
      }
    }
  }

} /* namespace od */
