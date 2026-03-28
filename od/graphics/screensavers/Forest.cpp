#include <od/graphics/screensavers/Forest.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cmath>
#include <cstring>

namespace od
{

  Forest::Forest()
  {
    reset();
  }

  Forest::~Forest()
  {
  }

  int Forest::fadeColor(int color, float fade)
  {
    int c = color - (int)(fade * 15.0f);
    return c < BLACK ? BLACK : c;
  }

  void Forest::initGrass()
  {
    for (int i = 0; i < GRASS_COUNT; i++)
    {
      grass[i].x = (int16_t)Random::generateFloat(0.0f, 255.0f);
      grass[i].height = 2 + Random::generateInteger(0, 3);
      grass[i].phase = Random::generateFloat(0.0f, 6.28f);
      grass[i].speed = Random::generateFloat(1.0f, 2.5f);
    }
  }

  void Forest::spawnTree()
  {
    if (treeCount >= MAX_TREES)
      return;

    int idx = treeCount++;

    // Random x position across the screen
    float baseX = Random::generateFloat(20.0f, 236.0f);

    GrowTask trunk;
    trunk.x = baseX;
    trunk.y = (float)(GROUND_Y + 1);
    trunk.angle = 1.5708f; // pi/2, straight up
    trunk.depth = 0;
    trunk.segmentsLeft = 5 + Random::generateInteger(0, 3);
    trunk.length = 4.0f + Random::generateFloat(0.0f, 3.0f);
    trunk.treeIndex = idx;

    if (growTop < MAX_GROW_STACK)
    {
      growStack[growTop++] = trunk;
    }

    treeFade[idx] = 0.0f;
    treeFading[idx] = false;
  }

  void Forest::reset()
  {
    segmentCount = 0;
    leafCount = 0;
    growTop = 0;
    treeCount = 0;
    treesFaded = 0;
    phase = GROWING;
    t = 0.0f;
    stepAccum = 0.0f;
    holdTimer = 0.0f;
    nextTreeTimer = 0.0f;
    allTreesSpawned = false;

    memset(treeFade, 0, sizeof(treeFade));
    memset(treeFading, 0, sizeof(treeFading));

    initGrass();
    spawnTree();
  }

  void Forest::draw(FrameBuffer &m, FrameBuffer &s)
  {
    t += GRAPHICS_REFRESH_PERIOD;
    if (t > 86400.0f)
      t = 0.0f;

    switch (phase)
    {
    case GROWING:
    {
      // Spawn additional trees over time
      if (!allTreesSpawned)
      {
        nextTreeTimer += GRAPHICS_REFRESH_PERIOD;
        if (nextTreeTimer >= 3.0f && treeCount < MAX_TREES)
        {
          spawnTree();
          nextTreeTimer = 0.0f;
        }
        if (treeCount >= MAX_TREES)
          allTreesSpawned = true;
      }

      stepAccum += 12.0f * GRAPHICS_REFRESH_PERIOD;
      while (stepAccum >= 1.0f && growTop > 0 &&
             segmentCount < MAX_SEGMENTS)
      {
        stepAccum -= 1.0f;

        GrowTask &task = growStack[growTop - 1];

        if (task.segmentsLeft <= 0 || task.depth >= 6)
        {
          if (leafCount < MAX_LEAVES)
          {
            Leaf &lf = leaves[leafCount++];
            lf.x = (int16_t)task.x;
            lf.y = (int16_t)task.y;
            lf.size = 1 + Random::generateInteger(0, 1);
            lf.treeIndex = task.treeIndex;
            if (Random::generateFloat(0.0f, 1.0f) < 0.3f)
            {
              int blossoms[] = {WHITE, GRAY13, GRAY14};
              lf.color = blossoms[Random::generateInteger(0, 2)];
            }
            else
            {
              lf.color = GRAY5 + Random::generateInteger(0, 3);
            }
          }
          growTop--;
          continue;
        }

        float wobble = Random::generateFloat(-0.2f, 0.2f);
        float ang = task.angle + wobble;
        float ex = task.x + task.length * cosf(ang);
        float ey = task.y + task.length * sinf(ang);

        if (ex < 2.0f)
          ex = 2.0f;
        if (ex > 254.0f)
          ex = 254.0f;
        if (ey < 2.0f)
          ey = 2.0f;
        if (ey > 62.0f)
          ey = 62.0f;

        if (ey >= 62.0f || ex <= 3.0f || ex >= 253.0f)
        {
          task.segmentsLeft = 0;
          continue;
        }

        Segment &seg = segments[segmentCount++];
        seg.x0 = (int16_t)task.x;
        seg.y0 = (int16_t)task.y;
        seg.x1 = (int16_t)ex;
        seg.y1 = (int16_t)ey;
        seg.depth = task.depth;
        seg.treeIndex = task.treeIndex;

        if (task.depth <= 1)
          seg.color = GRAY10;
        else if (task.depth <= 3)
          seg.color = GRAY7;
        else
          seg.color = GRAY5;

        task.x = ex;
        task.y = ey;
        task.segmentsLeft--;

        float branchProb = 0.35f - task.depth * 0.03f;
        if (branchProb < 0.05f)
          branchProb = 0.05f;

        if (Random::generateFloat(0.0f, 1.0f) < branchProb &&
            growTop < MAX_GROW_STACK - 1 && task.depth < 5)
        {
          float leftAngle = task.angle +
                            Random::generateFloat(0.3f, 0.7f);
          float rightAngle = task.angle -
                             Random::generateFloat(0.3f, 0.7f);
          float childLen = task.length * 0.72f;
          int childSegs = 3 + Random::generateInteger(0, 2);
          int childDepth = task.depth + 1;
          float cx = task.x;
          float cy = task.y;

          task.angle = leftAngle;
          task.depth = childDepth;
          task.segmentsLeft = childSegs;
          task.length = childLen;

          GrowTask right;
          right.x = cx;
          right.y = cy;
          right.angle = rightAngle;
          right.depth = childDepth;
          right.segmentsLeft = childSegs;
          right.length = childLen;
          right.treeIndex = task.treeIndex;
          growStack[growTop++] = right;
        }
      }

      // Transition to holding when all trees grown
      if (growTop == 0 && allTreesSpawned)
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
        // Start all trees fading
        for (int i = 0; i < treeCount; i++)
        {
          treeFading[i] = true;
        }
        treesFaded = 0;
      }
      break;
    }

    case FADING:
    {
      bool allDone = true;
      for (int i = 0; i < treeCount; i++)
      {
        if (treeFading[i])
        {
          // Stagger: each tree starts fading 0.4s after the previous
          float delay = i * 0.4f;
          float elapsed = treeFade[0]; // use first tree's fade as time base
          if (i == 0 || treeFade[i - 1] > 0.15f)
          {
            treeFade[i] += GRAPHICS_REFRESH_PERIOD / 2.5f;
          }
          if (treeFade[i] >= 1.0f)
          {
            treeFade[i] = 1.0f;
            treeFading[i] = false;
          }
          else
          {
            allDone = false;
          }
        }
      }
      if (allDone)
      {
        reset();
        return;
      }
      break;
    }
    }

    // --- Render ---

    // Compute global fade for ground/grass (use max tree fade)
    float globalFade = 0.0f;
    if (phase == FADING)
    {
      for (int i = 0; i < treeCount; i++)
      {
        if (treeFade[i] > globalFade)
          globalFade = treeFade[i];
      }
    }

    // Ground line
    int groundColor = fadeColor(GRAY4, globalFade);
    if (groundColor > BLACK)
    {
      m.hline(groundColor, 0, 255, GROUND_Y);
    }
    s.hline(WHITE, 0, 127, GROUND_Y);

    // Swaying grass
    for (int i = 0; i < GRASS_COUNT; i++)
    {
      GrassBlade &g = grass[i];
      float sway = sinf(t * g.speed + g.phase) * 1.5f;
      int bx = g.x;
      int tx = bx + (int)sway;

      if (tx < 0)
        tx = 0;
      if (tx > 255)
        tx = 255;

      int grassColor = fadeColor(GRAY6, globalFade);
      if (grassColor > BLACK)
      {
        // Draw a line from ground up, leaning with sway
        for (int h = 0; h < g.height; h++)
        {
          int py = GROUND_Y + 1 + h;
          if (py >= 64)
            break;
          // Interpolate x between base and tip
          float frac = (float)h / (float)(g.height - 1);
          int px = bx + (int)(sway * frac);
          if (px >= 0 && px < 256)
          {
            int c = (h == g.height - 1) ? fadeColor(GRAY4, globalFade) : grassColor;
            if (c > BLACK)
              m.pixel(c, px, py);
          }
        }
      }

      // Sub display grass (simplified)
      int sx = bx / 2;
      if (sx >= 0 && sx < 128)
      {
        s.pixel(WHITE, sx, GROUND_Y + 1);
        if (g.height > 2)
          s.pixel(WHITE, sx, GROUND_Y + 2);
      }
    }

    // Draw segments
    for (int i = 0; i < segmentCount; i++)
    {
      Segment &seg = segments[i];
      float fade = (phase == FADING) ? treeFade[seg.treeIndex] : 0.0f;
      int color = fadeColor(seg.color, fade);

      if (color > BLACK)
      {
        m.line(color, seg.x0, seg.y0, seg.x1, seg.y1);
        if (seg.depth <= 1)
        {
          m.line(color, seg.x0 + 1, seg.y0, seg.x1 + 1, seg.y1);
        }
      }

      float subFade = (phase == FADING) ? treeFade[seg.treeIndex] : 0.0f;
      int subColor = fadeColor(WHITE, subFade);
      if (subColor > BLACK)
      {
        s.line(subColor, seg.x0 / 2, seg.y0, seg.x1 / 2, seg.y1);
      }
    }

    // Draw leaves
    for (int i = 0; i < leafCount; i++)
    {
      Leaf &lf = leaves[i];
      float fade = (phase == FADING) ? treeFade[lf.treeIndex] : 0.0f;
      int color = fadeColor(lf.color, fade);

      if (color > BLACK)
      {
        m.fillCircle(color, lf.x, lf.y, lf.size);
      }

      int subColor = fadeColor(WHITE, fade);
      if (subColor > BLACK)
      {
        s.pixel(subColor, lf.x / 2, lf.y);
      }
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
