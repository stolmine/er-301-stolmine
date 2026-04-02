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

    float baseX = Random::generateFloat(8.0f, 248.0f);

    // Alternate height with upward bias
    bool tall = (idx % 2 == 0);
    int segs = tall ? 7 + Random::generateInteger(0, 4)
                    : 4 + Random::generateInteger(0, 2);
    float len = tall ? 5.0f + Random::generateFloat(0.0f, 4.0f)
                     : 3.0f + Random::generateFloat(0.0f, 2.0f);

    // Assign z layer: distribute trees across layers
    treeZ[idx] = idx % Z_LAYERS;

    GrowTask trunk;
    trunk.x = baseX;
    trunk.y = (float)(GROUND_Y + 1);
    trunk.angle = 1.5708f;
    trunk.depth = 0;
    trunk.segmentsLeft = segs;
    trunk.length = len;
    trunk.treeIndex = idx;

    if (growTop < MAX_GROW_STACK)
    {
      growStack[growTop++] = trunk;
    }

    treeFade[idx] = 0.0f;
    treeFading[idx] = false;
  }

  void Forest::initRays()
  {
    for (int i = 0; i < GODRAY_COUNT; i++)
      rays[i].active = false;
    raySpawnTimer = 0.0f;
  }

  void Forest::spawnRay(int i)
  {
    rays[i].x = Random::generateFloat(10.0f, 246.0f);
    rays[i].drift = Random::generateFloat(-0.15f, 0.15f);
    rays[i].angle = 1.0f;
    rays[i].width = Random::generateFloat(3.0f, 8.0f);
    rays[i].brightness = 0.0f;
    rays[i].life = 0.0f;
    rays[i].maxLife = Random::generateFloat(5.0f, 12.0f);
    rays[i].zLayer = Random::generateInteger(0, Z_LAYERS - 1);
    rays[i].active = true;
  }

  void Forest::updateRays()
  {
    raySpawnTimer += GRAPHICS_REFRESH_PERIOD;
    if (raySpawnTimer >= 1.5f)
    {
      raySpawnTimer = 0.0f;
      for (int i = 0; i < GODRAY_COUNT; i++)
      {
        if (!rays[i].active)
        {
          spawnRay(i);
          break;
        }
      }
    }

    for (int i = 0; i < GODRAY_COUNT; i++)
    {
      if (!rays[i].active)
        continue;

      rays[i].life += GRAPHICS_REFRESH_PERIOD;
      rays[i].x += rays[i].drift;

      float halfLife = rays[i].maxLife * 0.5f;
      if (rays[i].life < halfLife)
        rays[i].brightness = rays[i].life / halfLife;
      else
        rays[i].brightness = 1.0f - (rays[i].life - halfLife) / halfLife;

      if (rays[i].life >= rays[i].maxLife)
        rays[i].active = false;
    }
  }

  void Forest::drawRaysForLayer(FrameBuffer &m, FrameBuffer &s, int z)
  {
    for (int i = 0; i < GODRAY_COUNT; i++)
    {
      if (!rays[i].active || rays[i].zLayer != z)
        continue;

      float topX = rays[i].x;
      float hw = rays[i].width * 0.5f;
      float b = rays[i].brightness;
      float lean = rays[i].angle;

      for (int y = 0; y < 64; y++)
      {
        float yFrac = (float)y / 63.0f;
        float cx = topX + lean * (float)(63 - y);
        float rowHW = hw * (0.3f + 0.7f * yFrac);
        float rowB = b * yFrac * yFrac;
        int color = (int)(rowB * 12.0f);
        if (color <= 0)
          continue;
        if (color > GRAY10)
          color = GRAY10;

        int x0 = (int)(cx - rowHW);
        int x1 = (int)(cx + rowHW);
        if (x0 < 0) x0 = 0;
        if (x1 > 255) x1 = 255;
        for (int x = x0; x <= x1; x++)
        {
          int existing = m.readPixel(x, y);
          int combined = existing + color;
          if (combined > WHITE) combined = WHITE;
          m.pixel(combined, x, y);
        }
      }

      // Sub display
      for (int y = 0; y < 64; y++)
      {
        float yFrac = (float)y / 63.0f;
        float cx = topX + lean * (float)(63 - y);
        int sx = (int)(cx / 2.0f);
        if (sx >= 0 && sx < 128 && b * yFrac > 0.2f)
          s.pixel(WHITE, sx, y);
      }
    }
  }

  void Forest::initBirds()
  {
    for (int i = 0; i < BIRD_COUNT; i++)
      birds[i].active = false;
    birdSpawnTimer = 5.0f;
  }

  void Forest::updateAndDrawBirds(FrameBuffer &m, FrameBuffer &s)
  {
    birdSpawnTimer += GRAPHICS_REFRESH_PERIOD;
    if (birdSpawnTimer >= 8.0f)
    {
      birdSpawnTimer = 0.0f;
      for (int i = 0; i < BIRD_COUNT; i++)
      {
        if (!birds[i].active)
        {
          birds[i].x = -5.0f;
          birds[i].y = Random::generateFloat(40.0f, 60.0f);
          birds[i].speed = Random::generateFloat(0.4f, 0.9f);
          birds[i].wingPhase = Random::generateFloat(0.0f, 6.28f);
          birds[i].wingSpeed = Random::generateFloat(4.0f, 7.0f);
          birds[i].active = true;
          break;
        }
      }
    }

    for (int i = 0; i < BIRD_COUNT; i++)
    {
      if (!birds[i].active)
        continue;

      birds[i].x += birds[i].speed;
      birds[i].wingPhase += GRAPHICS_REFRESH_PERIOD * birds[i].wingSpeed;

      if (birds[i].x > 260.0f)
      {
        birds[i].active = false;
        continue;
      }

      int bx = (int)birds[i].x;
      int by = (int)birds[i].y;
      float wing = sinf(birds[i].wingPhase);
      int wy = (int)(wing * 2.0f);

      if (bx >= 0 && bx < 256 && by >= 0 && by < 64)
        m.pixel(WHITE, bx, by);
      int lx = bx - 2, rx = bx + 2;
      int ty = by + wy;
      if (lx >= 0 && lx < 256 && ty >= 0 && ty < 64)
        m.pixel(WHITE, lx, ty);
      if (rx >= 0 && rx < 256 && ty >= 0 && ty < 64)
        m.pixel(WHITE, rx, ty);
      int lx2 = bx - 1, rx2 = bx + 1;
      int ty2 = by + wy / 2;
      if (lx2 >= 0 && lx2 < 256 && ty2 >= 0 && ty2 < 64)
        m.pixel(WHITE, lx2, ty2);
      if (rx2 >= 0 && rx2 < 256 && ty2 >= 0 && ty2 < 64)
        m.pixel(WHITE, rx2, ty2);

      int sx = bx / 2;
      if (sx >= 0 && sx < 128 && by >= 0 && by < 64)
        s.pixel(WHITE, sx, by);
    }
  }

  void Forest::drawLayer(FrameBuffer &m, FrameBuffer &s, int z)
  {
    float fade = 0.0f;

    // Brightness dimming per layer: back=dimmer, front=brighter
    // z=0 back (-2), z=1 mid (0), z=2 front (+1)
    int zBrightness = (z == 0) ? -2 : (z == 2) ? 1 : 0;

    // Draw segments for this layer
    for (int i = 0; i < segmentCount; i++)
    {
      Segment &seg = segments[i];
      if (seg.zLayer != z)
        continue;

      fade = (phase == FADING) ? treeFade[seg.treeIndex] : 0.0f;
      int color = fadeColor(seg.color + zBrightness, fade);
      if (color < BLACK) color = BLACK;

      if (color > BLACK)
      {
        m.line(color, seg.x0, seg.y0, seg.x1, seg.y1);
        if (seg.depth <= 1)
        {
          m.line(color, seg.x0 + 1, seg.y0, seg.x1 + 1, seg.y1);
        }
      }

      int subColor = fadeColor(WHITE, fade);
      if (subColor > BLACK)
      {
        s.line(subColor, seg.x0 / 2, seg.y0, seg.x1 / 2, seg.y1);
      }
    }

    // Draw leaves for this layer
    for (int i = 0; i < leafCount; i++)
    {
      Leaf &lf = leaves[i];
      if (lf.zLayer != z)
        continue;

      fade = (phase == FADING) ? treeFade[lf.treeIndex] : 0.0f;
      int color = fadeColor(lf.color + zBrightness, fade);
      if (color < BLACK) color = BLACK;

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
    memset(treeZ, 0, sizeof(treeZ));

    initGrass();
    initRays();
    initBirds();
    spawnTree();
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
      if (!allTreesSpawned)
      {
        nextTreeTimer += GRAPHICS_REFRESH_PERIOD;
        if (nextTreeTimer >= 2.0f && treeCount < MAX_TREES)
        {
          spawnTree();
          if (treeCount < MAX_TREES)
            spawnTree();
          nextTreeTimer = 0.0f;
        }
        if (treeCount >= MAX_TREES)
          allTreesSpawned = true;
      }

      stepAccum += 24.0f * GRAPHICS_REFRESH_PERIOD;
      while (stepAccum >= 1.0f && growTop > 0 &&
             segmentCount < MAX_SEGMENTS)
      {
        stepAccum -= 1.0f;

        GrowTask &task = growStack[growTop - 1];
        uint8_t z = treeZ[task.treeIndex];

        if (task.segmentsLeft <= 0 || task.depth >= 7)
        {
          // More leaves per branch tip for thicker canopy
          int numLeaves = 1 + Random::generateInteger(0, 2);
          for (int n = 0; n < numLeaves && leafCount < MAX_LEAVES; n++)
          {
            Leaf &lf = leaves[leafCount++];
            lf.x = (int16_t)(task.x + Random::generateFloat(-2.0f, 2.0f));
            lf.y = (int16_t)(task.y + Random::generateFloat(-1.0f, 1.0f));
            lf.size = 1 + Random::generateInteger(0, 1);
            lf.treeIndex = task.treeIndex;
            lf.zLayer = z;
            if (Random::generateFloat(0.0f, 1.0f) < 0.2f)
            {
              int blossoms[] = {GRAY8, GRAY7, GRAY9};
              lf.color = blossoms[Random::generateInteger(0, 2)];
            }
            else
            {
              lf.color = GRAY3 + Random::generateInteger(0, 2);
            }
          }
          growTop--;
          continue;
        }

        float wobble = Random::generateFloat(-0.2f, 0.2f);
        float ang = task.angle + wobble;
        float ex = task.x + task.length * cosf(ang);
        float ey = task.y + task.length * sinf(ang);

        if (ex < 0.0f)
          ex = 0.0f;
        if (ex > 255.0f)
          ex = 255.0f;

        Segment &seg = segments[segmentCount++];
        seg.x0 = (int16_t)task.x;
        seg.y0 = (int16_t)task.y;
        seg.x1 = (int16_t)ex;
        seg.y1 = (int16_t)ey;
        seg.depth = task.depth;
        seg.treeIndex = task.treeIndex;
        seg.zLayer = z;

        if (task.depth <= 1)
          seg.color = GRAY6;
        else if (task.depth <= 3)
          seg.color = GRAY4;
        else
          seg.color = GRAY3;

        task.x = ex;
        task.y = ey;
        task.segmentsLeft--;

        // Higher branch probability for denser canopy
        float branchProb = 0.45f - task.depth * 0.03f;
        if (branchProb < 0.08f)
          branchProb = 0.08f;

        if (Random::generateFloat(0.0f, 1.0f) < branchProb &&
            growTop < MAX_GROW_STACK - 1 && task.depth < 6)
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
        for (int i = 0; i < treeCount; i++)
          treeFading[i] = true;
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
          if (i == 0 || treeFade[i - 1] > 0.15f)
            treeFade[i] += GRAPHICS_REFRESH_PERIOD / 2.5f;
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

    // Compute global fade for ground/grass
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
      m.hline(groundColor, 0, 255, GROUND_Y);
    s.hline(WHITE, 0, 127, GROUND_Y);

    // Swaying grass
    for (int i = 0; i < GRASS_COUNT; i++)
    {
      GrassBlade &g = grass[i];
      float sway = sinf(t * g.speed + g.phase) * 1.5f;
      int bx = g.x;

      int grassColor = fadeColor(GRAY4, globalFade);
      if (grassColor > BLACK)
      {
        for (int h = 0; h < g.height; h++)
        {
          int py = GROUND_Y + 1 + h;
          if (py >= 64)
            break;
          float frac = (float)h / (float)(g.height - 1);
          int px = bx + (int)(sway * frac);
          if (px >= 0 && px < 256)
          {
            int c = (h == g.height - 1) ? fadeColor(GRAY3, globalFade) : grassColor;
            if (c > BLACK)
              m.pixel(c, px, py);
          }
        }
      }

      int sx = bx / 2;
      if (sx >= 0 && sx < 128)
      {
        s.pixel(WHITE, sx, GROUND_Y + 1);
        if (g.height > 2)
          s.pixel(WHITE, sx, GROUND_Y + 2);
      }
    }

    // Update rays (position/brightness, no drawing yet)
    if (phase != FADING)
      updateRays();

    // Draw back-to-front: layer 0 (back), rays for layer, layer 1, rays, layer 2, rays
    for (int z = 0; z < Z_LAYERS; z++)
    {
      drawLayer(m, s, z);
      if (phase != FADING)
        drawRaysForLayer(m, s, z);
    }

    // Birds (always in front)
    if (phase != FADING)
      updateAndDrawBirds(m, s);

    // During growth, highlight active tips
    if (phase == GROWING)
    {
      for (int i = 0; i < growTop; i++)
        m.pixel(WHITE, (int)growStack[i].x, (int)growStack[i].y);
    }
  }

} /* namespace od */
