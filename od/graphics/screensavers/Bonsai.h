#pragma once

#include <od/graphics/ScreenSaver.h>
#include <cstdint>

namespace od
{

  class Bonsai : public ScreenSaver
  {
  public:
    Bonsai();
    virtual ~Bonsai();

    virtual void reset();
    virtual void draw(FrameBuffer &mainFrameBuffer,
                      FrameBuffer &subFrameBuffer);

  private:
    struct Segment
    {
      int16_t x0, y0, x1, y1;
      uint8_t depth;
      uint8_t color; // grayscale value for main display
    };

    struct GrowTask
    {
      float x, y;
      float angle;
      int depth;
      int segmentsLeft;
      float length;
    };

    struct Leaf
    {
      int16_t x, y;
      uint8_t size;
      uint8_t color;
    };

    static const int MAX_SEGMENTS = 400;
    static const int MAX_GROW_STACK = 64;
    static const int MAX_LEAVES = 80;

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

    Phase phase;
    float t = 0.0f;
    float stepAccum = 0.0f;
    float holdTimer = 0.0f;
    float fadeLevel = 0.0f;

    int fadeColor(int color);
  };

} /* namespace od */
