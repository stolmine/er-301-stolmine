#include <od/graphics/controls/SceneSlotIndicator.h>
#include <od/graphics/FrameBuffer.h>
#include <od/objects/Parameter.h>
#include <math.h>

namespace od
{

  SceneSlotIndicator::SceneSlotIndicator(int left, int bottom, int radius)
      : Graphic(left, bottom, 2 * radius + 1, 2 * radius + 1), mRadius(radius)
  {
  }

  SceneSlotIndicator::~SceneSlotIndicator()
  {
    setBias(0);
  }

  void SceneSlotIndicator::setBias(Parameter *param)
  {
    if (mpBias == param) return;
    if (mpBias) mpBias->release();
    mpBias = param;
    if (mpBias) mpBias->attach();
  }

  void SceneSlotIndicator::setSide(int side)
  {
    mSide = side;
  }

  void SceneSlotIndicator::draw(FrameBuffer &fb)
  {
    Graphic::draw(fb);

    int cx = mWorldLeft + mRadius;
    int cy = mWorldBottom + mRadius;

    // Outline: dim when unassigned, bright when this slot is part
    // of the live crossfade. The brighter outline plus the moving
    // fill is what the user reads as "this slot is engaged."
    Color outline = (mSide == kSideNone) ? GRAY5 : WHITE;
    fb.circle(outline, cx, cy, mRadius);

    if (mSide == kSideNone || mpBias == 0) return;

    // Live weight in [-1, +1]. Each slot fills only on its half
    // of the range: A on bias > 0, B on bias < 0.
    float bias = mpBias->value();
    float fillFrac;
    if (mSide == kSideA)
    {
      fillFrac = bias > 0.0f ? bias : 0.0f;
    }
    else
    {
      fillFrac = bias < 0.0f ? -bias : 0.0f;
    }
    if (fillFrac > 1.0f) fillFrac = 1.0f;
    if (fillFrac <= 0.0f) return;

    // Per-row horizontal wipe, clipped to the circle's chord at
    // that row. For row at dy: chord is [cx - dx, cx + dx] where
    // dx = sqrt(r^2 - dy^2). A-side draws from chord-left rightward
    // by chord_width * fillFrac; B-side mirrors from chord-right
    // leftward. Stays strictly inside the outline circle so the
    // edge never paints over the ring.
    int rsq = mRadius * mRadius;
    for (int dy = -mRadius + 1; dy <= mRadius - 1; dy++)
    {
      int dxsq = rsq - dy * dy;
      if (dxsq <= 0) continue;
      int dx = (int)sqrtf((float)dxsq) - 1;
      if (dx <= 0) continue;
      int chordLeft  = cx - dx;
      int chordRight = cx + dx;
      int chordWidth = chordRight - chordLeft;
      int fillWidth  = (int)(chordWidth * fillFrac + 0.5f);
      int y = cy + dy;
      if (mSide == kSideA)
      {
        if (fillWidth > 0)
        {
          fb.hline(WHITE, chordLeft, chordLeft + fillWidth, y);
        }
      }
      else
      {
        if (fillWidth > 0)
        {
          fb.hline(WHITE, chordRight - fillWidth, chordRight, y);
        }
      }
    }
  }

} /* namespace od */
