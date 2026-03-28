#include <od/graphics/screensavers/Rain.h>
#include <od/extras/Random.h>
#include <hal/constants.h>
#include <string.h>

namespace od
{

  Rain::Rain()
  {
    reset();
  }

  Rain::~Rain()
  {
  }

  void Rain::spawn(int i)
  {
    mX[i] = Random::generateFloat(0.0f, (float)(RAIN_MAIN_W - 1));
    mY[i] = (float)(RAIN_H - 1) + Random::generateFloat(0.0f, 10.0f);
    mSpeed[i] = Random::generateFloat(2.0f, 5.0f);
    mLength[i] = Random::generateInteger(2, 4);
    mBrightness[i] = Random::generateInteger(GRAY7, WHITE);
    mActive[i] = true;
  }

  void Rain::reset()
  {
    memset(mActive, 0, sizeof(mActive));
    memset(mSplashTimer, 0, sizeof(mSplashTimer));
  }

  void Rain::draw(FrameBuffer &m, FrameBuffer &s)
  {
    // Spawn new drops
    int toSpawn = Random::generateInteger(1, 3);
    for (int n = 0; n < toSpawn; n++)
    {
      for (int i = 0; i < RAIN_N; i++)
      {
        if (!mActive[i])
        {
          spawn(i);
          break;
        }
      }
    }

    // Update drops
    for (int i = 0; i < RAIN_N; i++)
    {
      if (!mActive[i])
        continue;

      mY[i] -= mSpeed[i];

      if (mY[i] < 0)
      {
        mActive[i] = false;
        // Create splash
        for (int j = 0; j < SPLASH_N; j++)
        {
          if (mSplashTimer[j] <= 0)
          {
            mSplashX[j] = (int)mX[i];
            mSplashTimer[j] = 3;
            break;
          }
        }
      }
    }

    // Draw drops on main display
    for (int i = 0; i < RAIN_N; i++)
    {
      if (!mActive[i])
        continue;
      int ix = (int)mX[i];
      int iy = (int)mY[i];
      int top = iy;
      int bot = iy - mLength[i];
      if (bot < 0)
        bot = 0;
      if (top >= RAIN_H)
        top = RAIN_H - 1;
      if (top >= bot && ix >= 0 && ix < RAIN_MAIN_W)
      {
        m.vline(mBrightness[i], ix, bot, top);
      }
      // Sub display (scaled x)
      int sx = ix / 2;
      if (top >= bot && sx >= 0 && sx < 128)
      {
        s.vline(mBrightness[i], sx, bot, top);
      }
    }

    // Draw and update splashes
    for (int j = 0; j < SPLASH_N; j++)
    {
      if (mSplashTimer[j] > 0)
      {
        int sx = mSplashX[j];
        int width = 2;
        int left = sx - width;
        int right = sx + width;
        if (left < 0)
          left = 0;
        if (right >= RAIN_MAIN_W)
          right = RAIN_MAIN_W - 1;
        m.hline(GRAY10, left, right, 0);

        // Sub display
        int sleft = left / 2;
        int sright = right / 2;
        if (sleft < 0)
          sleft = 0;
        if (sright >= 128)
          sright = 127;
        s.hline(GRAY10, sleft, sright, 0);

        mSplashTimer[j]--;
      }
    }
  }

} /* namespace od */
