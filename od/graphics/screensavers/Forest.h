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
      uint8_t zLayer;
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
      uint8_t zLayer;
    };

    struct GrassBlade
    {
      int16_t x;
      uint8_t height;
      float phase;
      float speed;
      float fade;       // 0=full brightness, 1=invisible
      float holdTimer;
      float holdDuration;
      enum { FADING_IN, HOLDING, FADING_OUT } state;
    };

    struct FallingParticle
    {
      float x, y;
      float speedY;
      float driftX;
      uint8_t color;
      uint8_t size;
      uint8_t zLayer;
      bool active;
    };

    static const int MAX_SEGMENTS = 4800;
    static const int MAX_GROW_STACK = 256;
    static const int MAX_LEAVES = 1600;
    static const int MAX_TREES = 16;
    static const int GRASS_COUNT = 80;
    static const int GODRAY_COUNT = 6;
    static const int BIRD_COUNT = 3;
    static const int PARTICLE_COUNT = 24;
    static const int GROUND_Y = 0;
    static const int Z_LAYERS = 3;

    struct GodRay
    {
      float x;
      float drift;
      float angle;
      float width;
      float brightness;
      float life;
      float maxLife;
      uint8_t zLayer;
      bool active;
    };

    // Per-tree lifecycle state
    enum TreeState
    {
      TREE_GROWING,
      TREE_HOLDING,
      TREE_FADING,
      TREE_DEAD
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
      uint8_t zLayer;
      bool active;
    };

    GrassBlade grass[GRASS_COUNT];
    GodRay rays[GODRAY_COUNT];
    Bird birds[BIRD_COUNT];
    FallingParticle particles[PARTICLE_COUNT];
    float raySpawnTimer;
    float birdSpawnTimer;
    float particleSpawnTimer;

    // Z-based brightness offset
    static constexpr int layerBrightness[Z_LAYERS] = {-3, 0, 2};
    static constexpr float layerScale[Z_LAYERS] = {0.7f, 1.0f, 1.2f};

    int treeCount;
    uint8_t treeZ[MAX_TREES];
    TreeState treeState[MAX_TREES];
    float treeFade[MAX_TREES];
    float treeHoldTimer[MAX_TREES];
    float treeHoldDuration[MAX_TREES];
    float treeSpawnDelay[MAX_TREES];

    float t;
    float stepAccum;
    float nextTreeTimer;

    void spawnTree();
    bool isTreeGrowing(int idx);
    void initGrass();
    void initRays();
    void spawnRay(int i);
    void initBirds();
    void initParticles();
    void updateAndDrawParticles(FrameBuffer &m, FrameBuffer &s);
    void drawLayer(FrameBuffer &m, FrameBuffer &s, int z);
    void drawRaysForLayer(FrameBuffer &m, FrameBuffer &s, int z);
    void updateRays();
    void updateAndDrawBirds(FrameBuffer &m, FrameBuffer &s);
    int fadeColor(int color, float fade);
  };

} /* namespace od */
