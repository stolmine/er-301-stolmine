#pragma once

#include <od/graphics/Graphic.h>

namespace od
{

  class Parameter;

  // Small hollow-circle indicator drawn on each scene-slot ply in
  // the hold-mode Performance view. When the slot is assigned to
  // crossfader endpoint A or B, fills in from the corresponding
  // side as the morpher's live weight Parameter moves through the
  // bipolar A<->B crossfade. Slot A fills left-to-right with
  // (1 + bias) / 2; slot B fills right-to-left with (1 - bias) / 2.
  // Both indicators always show their proportion; at bias=0 each
  // is half-filled and the pair reads as opposing crescents.
  // Unassigned slots draw only the hollow outline.
  //
  // The fill is a horizontal wipe clipped to the circle's profile:
  // each row inside the circle draws an hline whose length is
  // `chord_width * fillFrac`. Mimics "clip a rectangle to a circle
  // and keyframe it in" from any video editor.
  class SceneSlotIndicator : public Graphic
  {
  public:
    // Side constants exposed as ints (no enum) so Lua can pass them
    // directly without SWIG enum wrapping.
    static const int kSideNone = 0;
    static const int kSideA    = 1;
    static const int kSideB    = 2;

    SceneSlotIndicator(int left, int bottom, int radius);
    virtual ~SceneSlotIndicator();

#ifndef SWIGLUA
    virtual void draw(FrameBuffer &fb);
#endif

    // Bias parameter: typically morpher.getParameter("Weight"),
    // which is the live post-CV crossfade weight in [-1, +1].
    // +1 = full A, -1 = full B. Refcounted: caller can pass nullptr
    // to clear. Idempotent (same pointer = no-op).
    void setBias(Parameter *param);

    // kSideA / kSideB / kSideNone. Caller updates whenever the
    // slot's crossfader role changes (assignment toggle in
    // Performance view).
    void setSide(int side);

  private:
    Parameter *mpBias = 0;
    int mSide   = kSideNone;
    int mRadius;
  };

} /* namespace od */
