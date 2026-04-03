#include <od/graphics/screensavers/Forest.h>
#include <od/extras/Random.h>
#include <od/graphics/constants.h>
#include <hal/constants.h>
#include <cmath>
#include <cstring>

namespace od
{

  constexpr int Forest::layerBrightness[Z_LAYERS];
  constexpr float Forest::layerScale[Z_LAYERS];

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

  bool Forest::isTreeGrowing(int idx)
  {
    for (int i = 0; i < growTop; i++)
      if (growStack[i].treeIndex == idx)
        return true;
    return false;
  }

  void Forest::spawnTree()
  {
    if (treeCount >= MAX_TREES)
      return;

    int idx = treeCount++;

    float baseX = Random::generateFloat(8.0f, 248.0f);

    uint8_t z = idx % Z_LAYERS;
    treeZ[idx] = z;
    float scale = layerScale[z];

    bool forceTall = (idx < MAX_TREES / 2);
    bool tall = forceTall || (Random::generateFloat(0.0f, 1.0f) < 0.6f);

    int segs = tall ? (int)((7 + Random::generateInteger(0, 4)) * scale)
                    : (int)((4 + Random::generateInteger(0, 2)) * scale);
    float len = tall ? (5.0f + Random::generateFloat(0.0f, 4.0f)) * scale
                     : (3.0f + Random::generateFloat(0.0f, 2.0f)) * scale;
    if (segs < 3) segs = 3;

    GrowTask trunk;
    trunk.x = baseX;
    trunk.y = (float)(GROUND_Y + 1);
    trunk.angle = 1.5708f;
    trunk.depth = 0;
    trunk.segmentsLeft = segs;
    trunk.length = len;
    trunk.treeIndex = idx;

    if (growTop < MAX_GROW_STACK)
      growStack[growTop++] = trunk;

    treeState[idx] = TREE_GROWING;
    treeFade[idx] = 0.0f;
    treeHoldTimer[idx] = 0.0f;
    treeHoldDuration[idx] = Random::generateFloat(16.0f, 40.0f);
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
    float rayDim = (z == 0) ? 0.5f : (z == 1) ? 0.8f : 1.0f;

    for (int i = 0; i < GODRAY_COUNT; i++)
    {
      if (!rays[i].active || rays[i].zLayer != z)
        continue;

      float topX = rays[i].x;
      float hw = rays[i].width * 0.5f;
      float b = rays[i].brightness * rayDim;
      float lean = rays[i].angle;

      for (int y = 0; y < 64; y++)
      {
        float yFrac = (float)y / 63.0f;
        float cx = topX + lean * (float)(63 - y);
        float rowHW = hw * (0.3f + 0.7f * yFrac);
        float rowB = b * yFrac * yFrac;
        int color = (int)(rowB * 12.0f);
        if (color <= 0) continue;
        if (color > GRAY10) color = GRAY10;

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
          birds[i].zLayer = Random::generateInteger(0, Z_LAYERS - 1);
          birds[i].active = true;
          break;
        }
      }
    }

    for (int i = 0; i < BIRD_COUNT; i++)
    {
      if (!birds[i].active) continue;
      birds[i].x += birds[i].speed;
      birds[i].wingPhase += GRAPHICS_REFRESH_PERIOD * birds[i].wingSpeed;
      if (birds[i].x > 260.0f) { birds[i].active = false; continue; }
    }
  }

  void Forest::initParticles()
  {
    for (int i = 0; i < PARTICLE_COUNT; i++)
      particles[i].active = false;
    particleSpawnTimer = 0.0f;
  }

  void Forest::updateAndDrawParticles(FrameBuffer &m, FrameBuffer &s)
  {
    particleSpawnTimer += GRAPHICS_REFRESH_PERIOD;
    if (particleSpawnTimer >= 0.5f)
    {
      particleSpawnTimer = 0.0f;
      for (int i = 0; i < PARTICLE_COUNT; i++)
      {
        if (!particles[i].active)
        {
          particles[i].x = Random::generateFloat(0.0f, 255.0f);
          particles[i].y = 63.0f;
          particles[i].speedY = Random::generateFloat(0.15f, 0.35f);
          particles[i].driftX = Random::generateFloat(-0.2f, 0.1f);
          particles[i].zLayer = Random::generateInteger(0, Z_LAYERS - 1);
          particles[i].color = GRAY8 + Random::generateInteger(0, 4);
          particles[i].size = (Random::generateFloat(0.0f, 1.0f) < 0.3f) ? 2 : 1;
          particles[i].active = true;
          break;
        }
      }
    }

    for (int i = 0; i < PARTICLE_COUNT; i++)
    {
      if (!particles[i].active) continue;
      particles[i].y -= particles[i].speedY;
      particles[i].x += particles[i].driftX;
      if (particles[i].y < GROUND_Y) { particles[i].active = false; continue; }

      // Drawing handled per z-layer in render loop
    }
  }

  void Forest::drawLayer(FrameBuffer &m, FrameBuffer &s, int z)
  {
    int zBright = layerBrightness[z];

    for (int i = 0; i < segmentCount; i++)
    {
      Segment &seg = segments[i];
      if (seg.zLayer != z) continue;
      if (treeState[seg.treeIndex] == TREE_DEAD) continue;

      float fade = treeFade[seg.treeIndex];
      int color = fadeColor(seg.color + zBright, fade);
      if (color < BLACK) color = BLACK;

      if (color > BLACK)
      {
        m.line(color, seg.x0, seg.y0, seg.x1, seg.y1);
        if (seg.depth <= 1)
          m.line(color, seg.x0 + 1, seg.y0, seg.x1 + 1, seg.y1);
      }

      int subColor = fadeColor(WHITE, fade);
      if (subColor > BLACK)
        s.line(subColor, seg.x0 / 2, seg.y0, seg.x1 / 2, seg.y1);
    }

    for (int i = 0; i < leafCount; i++)
    {
      Leaf &lf = leaves[i];
      if (lf.zLayer != z) continue;
      if (treeState[lf.treeIndex] == TREE_DEAD) continue;

      float fade = treeFade[lf.treeIndex];
      int color = fadeColor(lf.color + zBright, fade);
      if (color < BLACK) color = BLACK;

      if (color > BLACK)
      {
        // Check for backlight from rays in previous layers
        int bg = m.readPixel(lf.x, lf.y);
        m.fillCircle(color, lf.x, lf.y, lf.size);

        // Rim light: bright edge on upper-right if backlit
        if (bg > GRAY3)
        {
          int rimColor = color + bg / 2;
          if (rimColor > WHITE) rimColor = WHITE;
          int rx = lf.x + lf.size;
          int ry = lf.y + 1;
          if (rx >= 0 && rx < 256 && ry >= 0 && ry < 64)
            m.pixel(rimColor, rx, ry);
        }
      }

      int subColor = fadeColor(WHITE, fade);
      if (subColor > BLACK)
        s.pixel(subColor, lf.x / 2, lf.y);
    }
  }

  void Forest::reset()
  {
    segmentCount = 0;
    leafCount = 0;
    growTop = 0;
    treeCount = 0;
    t = 0.0f;
    stepAccum = 0.0f;
    nextTreeTimer = 0.0f;

    memset(treeFade, 0, sizeof(treeFade));
    memset(treeState, 0, sizeof(treeState));
    memset(treeZ, 0, sizeof(treeZ));

    initGrass();
    initRays();
    initBirds();
    initParticles();
    spawnTree();
    spawnTree();
    spawnTree();
  }

  void Forest::draw(FrameBuffer &m, FrameBuffer &s)
  {
    t += GRAPHICS_REFRESH_PERIOD;
    if (t > 86400.0f) t = 0.0f;

    // Spawn new trees until initial batch is full
    if (treeCount < MAX_TREES)
    {
      nextTreeTimer += GRAPHICS_REFRESH_PERIOD;
      if (nextTreeTimer >= 1.5f)
      {
        spawnTree();
        nextTreeTimer = 0.0f;
      }
    }

    // Update per-tree lifecycle
    for (int i = 0; i < treeCount; i++)
    {
      switch (treeState[i])
      {
      case TREE_GROWING:
        if (!isTreeGrowing(i))
          treeState[i] = TREE_HOLDING;
        break;
      case TREE_HOLDING:
        treeHoldTimer[i] += GRAPHICS_REFRESH_PERIOD;
        if (treeHoldTimer[i] >= treeHoldDuration[i])
          treeState[i] = TREE_FADING;
        break;
      case TREE_FADING:
        treeFade[i] += GRAPHICS_REFRESH_PERIOD / 6.0f;
        if (treeFade[i] >= 1.0f)
        {
          treeFade[i] = 1.0f;
          treeState[i] = TREE_DEAD;

          // Remove segments and leaves for this tree, compact arrays
          int sw = 0;
          for (int j = 0; j < segmentCount; j++)
          {
            if (segments[j].treeIndex != i)
              segments[sw++] = segments[j];
          }
          segmentCount = sw;

          int lw = 0;
          for (int j = 0; j < leafCount; j++)
          {
            if (leaves[j].treeIndex != i)
              leaves[lw++] = leaves[j];
          }
          leafCount = lw;

          // Queue respawn after a delay
          treeSpawnDelay[i] = Random::generateFloat(2.0f, 8.0f);
        }
        break;
      case TREE_DEAD:
        treeSpawnDelay[i] -= GRAPHICS_REFRESH_PERIOD;
        if (treeSpawnDelay[i] <= 0.0f)
        {
          treeZ[i] = Random::generateInteger(0, Z_LAYERS - 1);
          float baseX = Random::generateFloat(8.0f, 248.0f);
          float scale = layerScale[treeZ[i]];
          bool tall = (Random::generateFloat(0.0f, 1.0f) < 0.6f);
          int segs = tall ? (int)((7 + Random::generateInteger(0, 4)) * scale)
                         : (int)((4 + Random::generateInteger(0, 2)) * scale);
          float len = tall ? (5.0f + Random::generateFloat(0.0f, 4.0f)) * scale
                          : (3.0f + Random::generateFloat(0.0f, 2.0f)) * scale;
          if (segs < 3) segs = 3;

          GrowTask trunk;
          trunk.x = baseX;
          trunk.y = (float)(GROUND_Y + 1);
          trunk.angle = 1.5708f;
          trunk.depth = 0;
          trunk.segmentsLeft = segs;
          trunk.length = len;
          trunk.treeIndex = i;

          if (growTop < MAX_GROW_STACK)
            growStack[growTop++] = trunk;

          treeState[i] = TREE_GROWING;
          treeFade[i] = 0.0f;
          treeHoldTimer[i] = 0.0f;
          treeHoldDuration[i] = Random::generateFloat(16.0f, 40.0f);
        }
        break;
      }
    }

    // Process growth: one step per active tree per tick (round-robin)
    stepAccum += 16.0f * GRAPHICS_REFRESH_PERIOD;
    while (stepAccum >= 1.0f && growTop > 0 &&
           segmentCount < MAX_SEGMENTS)
    {
      stepAccum -= 1.0f;

      bool processed[MAX_TREES] = {};
      int treesThisTick = 0;
      for (int si = growTop - 1; si >= 0; si--)
      {
        if (segmentCount >= MAX_SEGMENTS) break;
        if (treesThisTick >= 3) break;
        GrowTask &task = growStack[si];
        if (processed[task.treeIndex]) continue;
        processed[task.treeIndex] = true;
        treesThisTick++;

        uint8_t z = treeZ[task.treeIndex];

        if (task.segmentsLeft <= 0 || task.depth >= 7)
        {
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
          growStack[si] = growStack[growTop - 1];
          growTop--;
          si--;
          continue;
        }

        float wobbleRange = (task.depth <= 1) ? 0.08f : 0.2f;
        float wobble = Random::generateFloat(-wobbleRange, wobbleRange);
        float ang = task.angle + wobble;
        float ex = task.x + task.length * cosf(ang);
        float ey = task.y + task.length * sinf(ang);

        if (ex < -10.0f || ex > 265.0f)
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

        float branchProb = 0.45f - task.depth * 0.03f;
        if (branchProb < 0.08f)
          branchProb = 0.08f;

        if (Random::generateFloat(0.0f, 1.0f) < branchProb &&
            growTop < MAX_GROW_STACK - 1 && task.depth < 6)
        {
          float branchA = task.angle + Random::generateFloat(0.3f, 0.7f);
          float branchB = task.angle - Random::generateFloat(0.3f, 0.7f);
          float childLen = task.length * 0.72f;
          int childSegs = 3 + Random::generateInteger(0, 2);
          int childDepth = task.depth + 1;
          float cx = task.x;
          float cy = task.y;

          bool flipBranch = Random::generateFloat(0.0f, 1.0f) < 0.5f;
          task.angle = flipBranch ? branchB : branchA;
          task.depth = childDepth;
          task.segmentsLeft = childSegs;
          task.length = childLen;

          GrowTask branch;
          branch.x = cx;
          branch.y = cy;
          branch.angle = flipBranch ? branchA : branchB;
          branch.depth = childDepth;
          branch.segmentsLeft = childSegs;
          branch.length = childLen;
          branch.treeIndex = task.treeIndex;
          growStack[growTop++] = branch;
        }
      }
    }

    // --- Render ---

    // Ground line
    m.hline(GRAY4, 0, 255, GROUND_Y);
    s.hline(WHITE, 0, 127, GROUND_Y);

    // Swaying grass
    for (int i = 0; i < GRASS_COUNT; i++)
    {
      GrassBlade &g = grass[i];
      float sway = sinf(t * g.speed + g.phase) * 1.5f;
      int bx = g.x;

      for (int h = 0; h < g.height; h++)
      {
        int py = GROUND_Y + 1 + h;
        if (py >= 64) break;
        float frac = (float)h / (float)(g.height - 1);
        int px = bx + (int)(sway * frac);
        if (px >= 0 && px < 256)
        {
          int c = (h == g.height - 1) ? GRAY3 : GRAY4;
          m.pixel(c, px, py);
        }
      }

      int sx = bx / 2;
      if (sx >= 0 && sx < 128)
      {
        s.pixel(WHITE, sx, GROUND_Y + 1);
        if (g.height > 2) s.pixel(WHITE, sx, GROUND_Y + 2);
      }
    }

    // Update rays
    updateRays();

    // Update birds (position only)
    updateAndDrawBirds(m, s);

    // Draw back-to-front: trees, rays, birds per layer
    for (int z = 0; z < Z_LAYERS; z++)
    {
      drawLayer(m, s, z);
      drawRaysForLayer(m, s, z);

      // Draw birds at this z-layer
      for (int i = 0; i < BIRD_COUNT; i++)
      {
        if (!birds[i].active || birds[i].zLayer != z) continue;
        int bx = (int)birds[i].x;
        int by = (int)birds[i].y;
        float wing = sinf(birds[i].wingPhase);
        int wy = (int)(wing * 2.0f);

        if (bx >= 0 && bx < 256 && by >= 0 && by < 64)
          m.pixel(WHITE, bx, by);
        int lx = bx - 2, rx = bx + 2, ty = by + wy;
        if (lx >= 0 && lx < 256 && ty >= 0 && ty < 64) m.pixel(WHITE, lx, ty);
        if (rx >= 0 && rx < 256 && ty >= 0 && ty < 64) m.pixel(WHITE, rx, ty);
        int lx2 = bx - 1, rx2 = bx + 1, ty2 = by + wy / 2;
        if (lx2 >= 0 && lx2 < 256 && ty2 >= 0 && ty2 < 64) m.pixel(WHITE, lx2, ty2);
        if (rx2 >= 0 && rx2 < 256 && ty2 >= 0 && ty2 < 64) m.pixel(WHITE, rx2, ty2);

        int sx = bx / 2;
        if (sx >= 0 && sx < 128 && by >= 0 && by < 64) s.pixel(WHITE, sx, by);
      }

      // Draw particles at this z-layer
      int zBright = layerBrightness[z];
      for (int i = 0; i < PARTICLE_COUNT; i++)
      {
        if (!particles[i].active || particles[i].zLayer != z) continue;
        int px = (int)particles[i].x;
        int py = (int)particles[i].y;
        int pc = particles[i].color + zBright;
        if (pc < 1) pc = 1;
        if (pc > WHITE) pc = WHITE;
        if (px >= 0 && px < 256 && py >= 0 && py < 64)
        {
          m.pixel(pc, px, py);
          if (particles[i].size > 1)
          {
            if (px + 1 < 256) m.pixel(pc, px + 1, py);
            if (py - 1 >= 0) m.pixel(pc, px, py - 1);
          }
        }
        int psx = px / 2;
        if (psx >= 0 && psx < 128 && py >= 0 && py < 64)
          s.pixel(WHITE, psx, py);
      }
    }

    // Update particle positions
    updateAndDrawParticles(m, s);

    // Growth tips
    for (int i = 0; i < growTop; i++)
      m.pixel(WHITE, (int)growStack[i].x, (int)growStack[i].y);
  }

} /* namespace od */
