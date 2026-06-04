#include <od/graphics/controls/SceneSlotIndicator.h>
#include <od/graphics/FrameBuffer.h>
#include <od/objects/Parameter.h>
#include <math.h>

namespace od
{

  static inline float saturate(float x)
  {
    return x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x);
  }

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
    float r = (float)mRadius;

    // Outline brightness: dim when unassigned, bright when the
    // slot is bound to a crossfader endpoint.
    int outlineBright = (mSide == kSideNone) ? GRAY5 : WHITE;

    // Live A<->B mix fraction in [0, 1]. Matches the morpher's
    // linear bipolar crossfade:
    //   wA = (1 + bias) / 2      bias=+1 -> A full
    //   wB = 1 - wA              bias=-1 -> B full
    // Both indicators always show their proportion; at bias=0
    // each is half-filled (50/50 mix), reading as opposing
    // crescents that wax and wane in opposition as the user
    // moves the fader.
    float bias = mpBias ? mpBias->value() : 0.0f;
    float fillFrac = 0.0f;
    bool hasFill = (mSide != kSideNone) && mpBias != 0;
    if (hasFill)
    {
      if (bias < -1.0f) bias = -1.0f;
      else if (bias > 1.0f) bias = 1.0f;
      if (mSide == kSideA) fillFrac = (bias + 1.0f) * 0.5f;
      else                 fillFrac = (1.0f - bias) * 0.5f;
      if (fillFrac <= 0.0f) hasFill = false;
    }

    // Wipe boundary in pixel space (the moving edge of the fill).
    // A-side: x <= wipeBoundary is filled.
    // B-side: x >= wipeBoundary is filled.
    float wipeBoundary = 0.0f;
    if (hasFill)
    {
      float w = 2.0f * r * fillFrac;
      if (mSide == kSideA) wipeBoundary = (float)cx - r + w;
      else                 wipeBoundary = (float)cx + r - w;
    }

    // Per-pixel coverage. Bounding box extends one pixel past the
    // nominal radius to catch the antialiased outer edge.
    int reach = mRadius + 1;
    for (int dy = -reach; dy <= reach; dy++)
    {
      int y = cy + dy;
      for (int dx = -reach; dx <= reach; dx++)
      {
        int x = cx + dx;
        float fx = (float)dx;
        float fy = (float)dy;
        float dist = sqrtf(fx * fx + fy * fy);

        // Outline coverage: peaks at distance == r, falls to 0
        // at ±1 pixel. Treats the outline as a 1-pixel-wide ring
        // antialiased over the half-pixel transition on each
        // side. saturate(1 - |d - r|) gives a linear ramp.
        float outlineCov = saturate(1.0f - fabsf(dist - r));

        // Fill coverage: inside-circle * wipe.
        float fillCov = 0.0f;
        if (hasFill)
        {
          // Inside-circle coverage: 1 at distance < r - 0.5,
          // 0 at distance > r + 0.5. Linear AA over the boundary.
          float insideCircle = saturate((r + 0.5f) - dist);

          // Wipe coverage: 1 on the filled side of the wipe
          // boundary, 0 on the empty side, with a 1-pixel
          // linear ramp at the boundary so the edge of the
          // wipe is antialiased too (not just the circle's
          // perimeter -- otherwise the moving wipe edge would
          // show staircase artifacts every other frame).
          float wipeCov;
          if (mSide == kSideA) wipeCov = saturate(wipeBoundary - (float)x + 0.5f);
          else                 wipeCov = saturate((float)x - wipeBoundary + 0.5f);

          fillCov = insideCircle * wipeCov;
        }

        // Outline draws over fill: take the brighter of the two
        // per-pixel coverages. Both share the same color
        // (WHITE / GRAY5) so no need to composite separately --
        // just emit the higher-coverage shade.
        float coverage = outlineCov;
        int color = outlineBright;
        // When unassigned, no fill exists; when assigned, the
        // fill at the perimeter is naturally <= the outline
        // (insideCircle drops off at the same place outline
        // peaks). The outline wins at the edge; fill wins
        // inside; clean visual.
        if (fillCov > coverage)
        {
          coverage = fillCov;
          color = WHITE;
        }

        if (coverage <= 0.0f) continue;

        // Map coverage [0, 1] to a shade in [0, color]. Round to
        // integer grayscale level (the panel only supports 16
        // discrete shades; finer rounding wastes blend cost).
        int shade = (int)(color * coverage + 0.5f);
        if (shade <= 0) continue;
        if (shade > color) shade = color;
        fb.pixel((Color)shade, x, y);
      }
    }
  }

} /* namespace od */
