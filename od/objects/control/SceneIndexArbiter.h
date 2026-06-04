#pragma once

#include <od/objects/Object.h>
#include <od/objects/Inlet.h>
#include <od/objects/Outlet.h>
#include <od/objects/Parameter.h>

namespace od
{

  // Per-role selector for the v1.1 hold-mode scenes A/B faders.
  // Arbitrates among three writers (CV input, encoder via mBias,
  // chip tap via hardSetBias) using a 2-state machine.
  //
  // Output (mOutput) is the effective scene index as a float
  // (post-round, clipped to [0, mSceneCount]). The morpher's
  // IndexA/IndexB Inlets connect to this Outlet directly and read
  // the last-sample integer per frame; no Lua-side rebuild path
  // participates in scene-switch latency.
  //
  // mTransitionPending is a UI-only signal: when the integer
  // output changes, the audio thread sets it; SceneSlotControl's
  // UI frame handler polls it via consumeTransitionFlag to redraw
  // the A/B chip + bias-fill side. Audio switching does NOT
  // consume this flag.
  //
  // State machine:
  //   Tracking-Manual (cold-start): out = clip(round(bias))
  //     yields to Tracking-CV when |gain_at_entry * (cvIn -
  //     cv_at_entry)| > 0.5 in output-space units.
  //   Tracking-CV: out = clip(round(gain * cvIn))
  //     yields to Tracking-Manual on any hardSetBias() call.
  //   No idle decay; only CV movement releases Tracking-Manual.
  class SceneIndexArbiter : public Object
  {
  public:
    SceneIndexArbiter();
    virtual ~SceneIndexArbiter();

#ifndef SWIGLUA
    virtual void process();

    // CV input. Scaled internally by mGain to produce candidate
    // index = round(mGain * cvIn). When unpatched, buffer is
    // ZeroOutput and arbiter sits in Tracking-Manual at startup.
    Inlet mInput{"In"};
    // Output as float for fader animation; round() to int for
    // morpher consumption.
    Outlet mOutput{"Out"};
#endif

    // User-facing Parameters. Both saved by the chain.
    Parameter mGain{"Gain", 1.0f};  // range +-32 (clamped at write)
    Parameter mBias{"Bias", 0.0f};  // range [0, mSceneCount]

    // Bank size in scenes. Clips mBias and mOutput. Lua sets this
    // from Chain.Root after SceneView add/delete.
    void setSceneCount(int n);
    int getSceneCount() const { return mSceneCount; }

    // Manual-write entry point. Called by Lua chip-tap and encoder
    // handlers. Hard-sets mBias, forces Tracking-Manual, latches
    // CV-at-entry baseline. Triggers an integer transition signal
    // (UI redraw) if the effective output index changes.
    //
    // No morpher rebuild call needed: the morpher consumes the new
    // index from mOutput via its IndexA/IndexB Inlets on the next
    // audio frame.
    void hardSetBias(float value);

    // Lua polls this each UI frame. Returns true once when a
    // transition has fired since the last poll, then auto-clears.
    bool consumeTransitionFlag();

    // Diagnostics / introspection for views and tests.
    enum State { kTrackingManual = 0, kTrackingCV = 1 };
    int getState() const { return (int)mState; }
    int getCurrentIndex() const { return mLastFiredIndex; }

  protected:
    int mSceneCount = 0;
    State mState = kTrackingManual;

    // Input-space CV baseline + Gain captured on Manual entry.
    // Schmitt comparison uses frozen Gain so a live Gain change
    // doesn't spuriously trip the state transition.
    float mCVInputAtEntry = 0.0f;
    float mGainAtEntry = 1.0f;

    // Cached last CV sample from process() so hardSetBias() (Lua
    // thread) has a stable baseline when latching mCVInputAtEntry.
    float mLastCVSample = 0.0f;

    // Last integer output we fired a transition for. Compared
    // against current round(effective) each frame to detect edges.
    int mLastFiredIndex = 0;

    // UI redraw signal. Audio-thread write, Lua-thread read+clear
    // via consumeTransitionFlag. Single-writer / single-reader on
    // a plain bool; missed flag = missed redraw, self-correcting
    // on next frame. Audio path does not consume this.
    bool mTransitionPending = false;

    // clip(x) = max(0, min(x, mSceneCount))
    int clipIndex(int v) const;

    // Effective integer output for current inputs + state.
    int computeEffectiveIndex(float cvIn, float gain, float bias) const;

    // Schmitt: returns true when CV has moved more than 0.5 in
    // output-space units (with frozen entry Gain) since Manual
    // entry. Caller checks state == Tracking-Manual first.
    bool shouldYieldToCV(float cvIn) const;
  };

} /* namespace od */
