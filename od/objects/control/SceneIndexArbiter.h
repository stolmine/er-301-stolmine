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
  // kIndex semantics: Bias and CV input live in a normalized [0,
  // 1] domain (a fraction-of-bank position). Output index is
  // round(... * mSceneCount), clipped to [0, mSceneCount]. Same
  // input always selects the same fractional position regardless
  // of bank size, so the fader's encoder feel and the CV mapping
  // don't change when scenes are added or removed.
  //
  // mTransitionPending is a UI-only signal: when the integer
  // output changes, the audio thread sets it; SceneSlotControl's
  // UI frame handler polls it via consumeTransitionFlag to redraw
  // the A/B chip + bias-fill side. Audio switching does NOT
  // consume this flag.
  //
  // State machine:
  //   Tracking-Manual (cold-start): out = round(Bias * N), clipped.
  //     Yields to Tracking-CV when |GainAtEntry * (cvIn -
  //     CVAtEntry) * N| > 0.5 (Schmitt in scene-index space).
  //   Tracking-CV: out = round(Gain * cvIn * N), clipped.
  //     Yields to Tracking-Manual on any hardSetBias() call.
  //   No idle decay; only CV movement releases Tracking-Manual.
  //   Cold-start Gain = 0 means CV is inert until the user dials
  //   Gain up -- the Schmitt comparison evaluates to 0 and never
  //   trips, so patching a CV source has no effect on the audible
  //   selection until Gain is enabled.
  class SceneIndexArbiter : public Object
  {
  public:
    SceneIndexArbiter();
    virtual ~SceneIndexArbiter();

#ifndef SWIGLUA
    virtual void process();

    // CV input. Treated as a normalized [0, 1] selection (last
    // sample read per frame). Scaled internally to bank-relative
    // position. When unpatched, buffer is ZeroOutput; with the
    // cold-start Gain=0 this leaves the arbiter inert until the
    // user enables Gain.
    Inlet mInput{"In"};
    // Integer scene index output (0..N as float). Morpher reads
    // last-sample via its IndexA/IndexB Inlets.
    Outlet mOutput{"Out"};
    // Normalized [0, 1] effective position output, pre-round.
    // Drives the M2/M3 fader's MinMax range bar so the swing
    // visualization is in the same coord system as the fader.
    // Tracking-Manual: equals Bias. Tracking-CV: clamp(Gain *
    // cvIn, 0, 1).
    Outlet mOutputNorm{"OutNorm"};
#endif

    // User-facing Parameters. Both saved by the chain.
    //
    // Gain: CV input scaler. Default 0 = CV inert. Standard 301
    // gain map (+-10) is wide enough -- with input normalized to
    // [0, 1] domain, Gain=1 means "full input swing = full bank";
    // Gain=2 means "half input swing = full bank" (good for LFOs
    // that only swing +-0.5). Larger Gain not musically useful.
    //
    // Bias: normalized [0, 1] manual home position. Encoder + chip
    // tap write here. Output in Tracking-Manual = round(Bias * N).
    Parameter mGain{"Gain", 0.0f};
    Parameter mBias{"Bias", 0.0f};

    // Bank size in scenes. Used to scale Bias / CV to integer
    // output and to clip the output to [0, N]. Lua sets this from
    // Chain.Root after SceneView add/delete. Bias is normalized
    // and bank-independent, so add/delete does NOT shrink it --
    // the user's manual home stays at the same fractional position
    // and the output naturally reaches further as N grows.
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
    // doesn't spuriously trip the state transition. Default
    // Gain = 0 matches the cold-start Parameter so Schmitt
    // evaluates to 0 -> never trips until first manual write
    // bumps mGainAtEntry from whatever the user has set.
    float mCVInputAtEntry = 0.0f;
    float mGainAtEntry = 0.0f;

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
