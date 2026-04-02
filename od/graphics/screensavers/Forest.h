#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Forest : public ScreenSaver
  {
  public:
    Forest();
    virtual ~Forest();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    struct Segment
    {
      int16_t x0, y0, x1, y1;
      uint8_t depth;
      uint8_t color;
      uint8_t treeIndex;
    };

    struct GrowTask
    {
      float x, y;
      float angle;
      int depth;
      int segmentsLeft;
      float length;
      uint8_t treeIndex;
    };

    struct Leaf
    {
      int16_t x, y;
      uint8_t size;
      uint8_t color;
      uint8_t treeIndex;
    };

    struct GrassBlade
    {
      int16_t x;
      uint8_t height;
      float phase;
      float speed;
    };

    static const int MAX_SEGMENTS = 1600;
    static const int MAX_GROW_STACK = 128;
    static const int MAX_LEAVES = 400;
    static const int MAX_TREES = 16;
    static const int GRASS_COUNT = 80;
    static const int GODRAY_COUNT = 5;
    static const int BIRD_COUNT = 3;
    static const int GROUND_Y = 5;

    struct GodRay
    {
      float x;
      float drift;
      float angle; // x offset per y pixel (lean)
      float width;
      float brightness;
      float life;
      float maxLife;
      bool active;
    };

    enum Phase
    {
      GROWING,
      HOLDING,
      FADING
    };

    Segment segments[MAX_SEGMENTS];
    int segmentCount;

    GrowTask growStack[MAX_GROW_STACK];
    int growTop;

    Leaf leaves[MAX_LEAVES];
    int leafCount;

    struct Bird
    {
      float x, y;
      float speed;
      float wingPhase;
      float wingSpeed;
      bool active;
    };

    GrassBlade grass[GRASS_COUNT];
    GodRay rays[GODRAY_COUNT];
    Bird birds[BIRD_COUNT];
    float raySpawnTimer;
    float birdSpawnTimer;

    int treeCount;
    float treeFade[MAX_TREES]; // per-tree fade level (0 = solid, 1 = gone)
    bool treeFading[MAX_TREES];
    int treesFaded;

    Phase phase;
    float t;
    float stepAccum;
    float holdTimer;
    float nextTreeTimer;
    bool allTreesSpawned;

    void spawnTree();
    void initGrass();
    void initRays();
    void spawnRay(int i);
    void updateAndDrawRays(FrameBuffer &m, FrameBuffer &s);
    void initBirds();
    void updateAndDrawBirds(FrameBuffer &m, FrameBuffer &s);
    int fadeColor(int color, float fade);
  };

} /* namespace od */
