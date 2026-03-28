#include <od/graphics/screensavers/Bonsai.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cmath>
#include <cstring>

namespace od
{

  Bonsai::Bonsai()
  {
    reset();
  }

  Bonsai::~Bonsai()
  {
  }

  int Bonsai::fadeColor(int color)
  {
    int c = color - (int)(fadeLevel * 15.0f);
    return c < BLACK ? BLACK : c;
  }

  void Bonsai::reset()
  {
    segmentCount = 0;
    leafCount = 0;
    growTop = 0;
    phase = GROWING;
    t = 0.0f;
    stepAccum = 0.0f;
    holdTimer = 0.0f;
    fadeLevel = 0.0f;

    // Push initial trunk
    GrowTask trunk;
    trunk.x = 128.0f;
    trunk.y = 5.0f;
    trunk.angle = 1.5708f; // pi/2, straight up
    trunk.depth = 0;
    trunk.segmentsLeft = 6 + Random::generateInteger(0, 3);
    trunk.length = 6.0f;
    growStack[growTop++] = trunk;
  }

  void Bonsai::draw(FrameBuffer &m, FrameBuffer &s)
  {
    t += GRAPHICS_REFRESH_PERIOD;
    if (t > 86400.0f)
      t = 0.0f;

    switch (phase)
    {
    case GROWING:
    {
      stepAccum += 12.0f * GRAPHICS_REFRESH_PERIOD;
      while (stepAccum >= 1.0f && growTop > 0 &&
             segmentCount < MAX_SEGMENTS)
      {
        stepAccum -= 1.0f;

        GrowTask &task = growStack[growTop - 1];

        // Branch exhausted or max depth — add leaf and pop
        if (task.segmentsLeft <= 0 || task.depth >= 7)
        {
          if (leafCount < MAX_LEAVES)
          {
            Leaf &lf = leaves[leafCount++];
            lf.x = (int16_t)task.x;
            lf.y = (int16_t)task.y;
            lf.size = 1 + Random::generateInteger(0, 1);
            // 40% blossom, 60% foliage
            if (Random::generateFloat(0.0f, 1.0f) < 0.4f)
            {
              int blossoms[] = {WHITE, GRAY13, GRAY14};
              lf.color = blossoms[Random::generateInteger(0, 2)];
            }
            else
            {
              lf.color = GRAY6 + Random::generateInteger(0, 2);
            }
          }
          growTop--;
          continue;
        }

        // Grow one segment
        float wobble = Random::generateFloat(-0.15f, 0.15f);
        float ang = task.angle + wobble;
        float ex = task.x + task.length * cosf(ang);
        float ey = task.y + task.length * sinf(ang);

        // Clamp to screen
        if (ex < 2.0f) ex = 2.0f;
        if (ex > 254.0f) ex = 254.0f;
        if (ey < 2.0f) ey = 2.0f;
        if (ey > 62.0f) ey = 62.0f;

        // Terminate if we've hit screen edges
        if (ey >= 62.0f || ex <= 3.0f || ex >= 253.0f)
        {
          task.segmentsLeft = 0;
          continue;
        }

        // Store segment
        Segment &seg = segments[segmentCount++];
        seg.x0 = (int16_t)task.x;
        seg.y0 = (int16_t)task.y;
        seg.x1 = (int16_t)ex;
        seg.y1 = (int16_t)ey;
        seg.depth = task.depth;

        // Color based on depth: trunk bright, branches dimmer
        if (task.depth <= 1)
          seg.color = GRAY10;
        else if (task.depth <= 3)
          seg.color = GRAY7;
        else
          seg.color = GRAY5;

        task.x = ex;
        task.y = ey;
        task.segmentsLeft--;

        // Decide whether to fork
        float branchProb = 0.35f - task.depth * 0.03f;
        if (branchProb < 0.05f)
          branchProb = 0.05f;

        if (Random::generateFloat(0.0f, 1.0f) < branchProb &&
            growTop < MAX_GROW_STACK - 1 && task.depth < 6)
        {
          float leftAngle = task.angle +
                            Random::generateFloat(0.3f, 0.7f);
          float rightAngle = task.angle -
                             Random::generateFloat(0.3f, 0.7f);
          float childLen = task.length * 0.75f;
          int childSegs = 3 + Random::generateInteger(0, 3);
          int childDepth = task.depth + 1;
          float cx = task.x;
          float cy = task.y;

          // Replace current task with left branch
          task.angle = leftAngle;
          task.depth = childDepth;
          task.segmentsLeft = childSegs;
          task.length = childLen;

          // Push right branch
          GrowTask right;
          right.x = cx;
          right.y = cy;
          right.angle = rightAngle;
          right.depth = childDepth;
          right.segmentsLeft = childSegs;
          right.length = childLen;
          growStack[growTop++] = right;
        }
      }

      if (growTop == 0)
      {
        phase = HOLDING;
        holdTimer = 0.0f;
      }
      break;
    }

    case HOLDING:
    {
      holdTimer += GRAPHICS_REFRESH_PERIOD;
      if (holdTimer >= 6.0f)
      {
        phase = FADING;
        fadeLevel = 0.0f;
      }
      break;
    }

    case FADING:
    {
      fadeLevel += GRAPHICS_REFRESH_PERIOD / 2.0f;
      if (fadeLevel >= 1.0f)
      {
        reset();
        return; // skip rendering this frame, next frame draws fresh
      }
      break;
    }
    }

    // --- Render ---

    // Ground line and pot (main)
    int groundColor = (phase == FADING) ? fadeColor(GRAY4) : GRAY4;
    int potColor = (phase == FADING) ? fadeColor(GRAY6) : GRAY6;

    if (groundColor > BLACK)
    {
      m.hline(groundColor, 0, 255, 2);
      m.fill(potColor, 118, 0, 138, 4);
    }
    // Sub display ground and pot
    s.hline(WHITE, 0, 127, 2);
    s.fill(WHITE, 59, 0, 69, 4);

    // Draw segments
    for (int i = 0; i < segmentCount; i++)
    {
      Segment &seg = segments[i];
      int color = (phase == FADING) ? fadeColor(seg.color) : seg.color;

      if (color > BLACK)
      {
        m.line(color, seg.x0, seg.y0, seg.x1, seg.y1);
        // Thicker trunk: draw offset line
        if (seg.depth <= 1)
        {
          m.line(color, seg.x0 + 1, seg.y0, seg.x1 + 1, seg.y1);
        }
      }

      // Sub display: scale X by half
      s.line(WHITE, seg.x0 / 2, seg.y0, seg.x1 / 2, seg.y1);
    }

    // Draw leaves
    for (int i = 0; i < leafCount; i++)
    {
      Leaf &lf = leaves[i];
      int color = (phase == FADING) ? fadeColor(lf.color) : lf.color;

      if (color > BLACK)
      {
        m.fillCircle(color, lf.x, lf.y, lf.size);
      }

      s.pixel(WHITE, lf.x / 2, lf.y);
    }

    // During growth, highlight active tips
    if (phase == GROWING)
    {
      for (int i = 0; i < growTop; i++)
      {
        m.pixel(WHITE, (int)growStack[i].x, (int)growStack[i].y);
      }
    }
  }

} /* namespace od */
