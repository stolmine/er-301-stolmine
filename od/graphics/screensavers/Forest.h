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

    static const int MAX_SEGMENTS = 600;
    static const int MAX_GROW_STACK = 64;
    static const int MAX_LEAVES = 120;
    static const int MAX_TREES = 5;
    static const int GRASS_COUNT = 80;
    static const int GROUND_Y = 5;

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

    GrassBlade grass[GRASS_COUNT];

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
    int fadeColor(int color, float fade);
  };

} /* namespace od */
